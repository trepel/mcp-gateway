# MCP Routing Strategy

## Problem

The MCP Gateway router is an ext_proc gRPC server that parses JSON-RPC bodies and sets the `:authority` header to route requests to the correct backend MCP server. This adds a gRPC round-trip per request on the hot path (`tools/call`). As Envoy gains native MCP support and Praxis emerges as a potential proxy replacement, we need to decide where to invest for this routing logic in the medium to long term.

Simultaneously, the MCP protocol itself is undergoing its largest revision. The `2026-07-28` spec removes the `initialize`/`initialized` handshake, removes `Mcp-Session-Id`, and makes every request self-contained and stateless. New `Mcp-Method` and `Mcp-Name` headers make routing possible without body inspection. This fundamentally changes the routing problem — and the value proposition of the ext_proc.

The decision is constrained by an October 2026 delivery target for a v1 of MCP Gateway.

### Evaluation inputs

- **CONNLINK-1026**: gap analysis of Envoy 1.38 native MCP filters vs MCP Gateway
- **Praxis research**: evaluation of Praxis as router and gateway [praxis](https://github.com/praxis-proxy/praxis)
- **MCP `2026-07-28` RC**: stateless protocol revision [spec ships July 28, 2026](https://modelcontextprotocol.io/specification/draft)

## Constraints

1. **Gateway API is the user-facing API.** Kuadrant policies (AuthPolicy, RateLimitPolicy, TokenRateLimitPolicy) attach to Gateway API resources — HTTPRoute for per-server policies, Gateway for gateway-wide policies. Users create individual HTTPRoutes per MCP backend and attach policies to them. This model must be preserved regardless of which proxy or routing mechanism is used underneath.

2. **Per-server policy enforcement requires routable identity.** Today this works because the router sets `:authority` to the backend's HTTPRoute hostname, causing traffic to flow through that route where policies are evaluated by the wasm-shim. Any replacement must preserve this routing signal (`:authority` or equivalent) so that the policy enforcement layer — whether wasm-shim on Envoy or a native filter on Praxis — can match traffic to the correct policy config. The enforcement backend can change (Kuadrant operator reconciling into Praxis filter config instead of wasm-shim), but the routing signal that associates a request with a specific MCP server's policies cannot be lost.

3. **Single entry point with `:authority` rewrite.** Clients connect to a single public endpoint (`mcp.example.com/mcp`). They do not address individual backends directly. A filter must: (a) validate the request is using the expected public listener host to prevent clients bypassing the broker and hitting backends directly, (b) rewrite `:authority` to the backend's HTTPRoute hostname so Envoy routes through the correct HTTPRoute where policies attach, and (c) when `prefix` is set on the MCPServerRegistration, strip the prefix from the tool name in the JSON-RPC body and rewrite the `Mcp-Name` header. For `2026-07-28` traffic without prefix, the router operates entirely on headers — no body access needed. Body access is only required for prefix stripping in the router; all other body parsing (`_meta` inspection, `inputResponses`/`requestState`, tool list construction) is the broker's concern. Gateway API HTTPRoute header matching can select a `backendRef` but cannot rewrite `:authority` to re-enter the routing table through a different HTTPRoute — a filter is still required.

4. **Dual-support requirement.** We must support both `2025-11-25` (stateful, session-based) and `2026-07-28` (stateless, header-routable) clients during a transition period. The `MCP-Protocol-Version` header distinguishes them. This means the routing solution must handle both modes simultaneously.

## Context

### Current architecture

```
Client → Envoy → ext_proc (Go gRPC) → Envoy routes to backend
```

The router handles:
- JSON-RPC parsing and method dispatch
- Tool/prompt name prefix stripping and body rewriting
- Backend session management (lazy init, singleflight, Redis/in-memory)
- Header injection (`:authority`, `mcp-session-id`, `x-mcp-*`)
- Response handling (session ID mapping, 404-based invalidation)
- Elicitation ID rewriting

### MCP `2026-07-28` protocol changes

The upcoming spec revision fundamentally changes the routing landscape. Key changes:

**Session removal.** The `initialize`/`initialized` handshake and `Mcp-Session-Id` are removed. Every request is self-contained. This eliminates the router's session management responsibilities (lazy init, session ID mapping, singleflight, Redis/in-memory cache, 404-based invalidation). This is a large chunk of the router's current complexity.

**Header-based routing.** `Mcp-Method` and `Mcp-Name` headers are now required on every request. A gateway can route `tools/call` for tool `search` by inspecting `Mcp-Method: tools/call` and `Mcp-Name: search` — no body parsing needed. This is standard HTTP header routing that Envoy (or any proxy) can do natively without ext_proc.

**Stateless elicitation.** Server-to-client requests (elicitation) are restructured as `InputRequiredResult` responses with an opaque `requestState` token. The client re-issues the original call with `inputResponses` and the echoed state. No SSE stream, no session, no ID rewriting. The router's elicitation ID rewriting logic becomes unnecessary.

**Client-side caching.** `tools/list` responses carry `ttlMs` and `cacheScope`, modeled on HTTP `Cache-Control`. Clients cache tool lists and don't need long-lived SSE streams to learn about changes. This reduces the broker's caching advantage over Envoy's fanout model — clients absorb the caching responsibility.

### What remains after `2026-07-28`

With sessions and body-based routing removed, the router's primary remaining responsibilities are prefix management and header injection.

### Praxis as the gateway

Praxis may emerge as an alternative to Envoy as the gateway proxy over time. If this happens, the ext_proc pattern disappears — there is no Envoy to extend. MCP routing, policy enforcement, TLS, load balancing, and observability all become native Praxis filters.

This doesn't change the October decision directly — Praxis at 0.3.1 is not ready to replace Envoy as a production gateway. But it should influence how we invest:

- **Work that survives the transition:** Gateway API CRDs as the user-facing API. Controller reconciliation logic. The routing decision model (which server handles which tool). Per-server policy attachment via HTTPRoute. These are proxy-agnostic.
- **Work that doesn't survive:** Anything coupled to Envoy's ext_proc interface, EnvoyFilter resources.

## Options

### Option 1: Portable routing core → Praxis filter

Refactor the routing logic behind a clean `Router` interface. The ext_proc becomes a thin adapter over a portable routing core. The same routing contract is later reimplemented as a Rust Praxis filter.

**Architecture:**

```
                      Router interface
                      (routing decisions: target host, headers, body mutations)
                          │
              ┌───────────┴───────────┐
              │                       │
    ExtProcAdapter (Go)       PraxisAdapter (Rust)
    gRPC stream translation   HttpFilter trait translation
              │                       │
          ext_proc                Praxis filter
    (Phase 1: Oct GA)         (Phase 2: post-GA)
```

The `Router` interface takes a request representation and returns routing decisions. It has no knowledge of ext_proc, gRPC streams, Envoy, or Praxis. Each adapter translates between its platform and the routing core.

**What the routing core handles:**
- Tool/prompt name → server lookup from routing table config
- `:authority` rewrite to backend HTTPRoute hostname
- Prefix stripping (body `name` field + `Mcp-Name` header) when configured
- Host validation (prevent bypass to backends)
- Protocol branching: `2026-07-28` (header-based) vs `2025-11-25` (body-based + sessions)

**What stays in the adapter:**
- ext_proc: gRPC stream handling, ext_proc phase mapping
- Praxis: `HttpFilter` trait, `StreamBuffer` for body access, `FilterAction` returns

**Kuadrant policy impact:** Preserved. The adapter sets `:authority`, traffic flows through per-server HTTPRoutes, policies evaluate as today. If Praxis becomes the main target, the operator reconciles policy CRDs into Praxis-native filter config — separate workstream.

**Advantages:**
- Keeps what works today for October GA — no new runtime risk
- Clean separation enables unit testing routing logic without ext_proc mocking
- The `Router` interface is the specification for the Praxis port — a tested contract, not a guess
- `2025-11-25` code path is explicitly isolated and disposable
- `2026-07-28` path through ext_proc is header-only when no prefix (minimal overhead)
- Praxis filter is a Rust reimplementation of a known interface, not a greenfield design

**Risks:**
- ext_proc latency remains until Praxis filter replaces it
- Interface design could need revision when the Praxis adapter is built
- Maintaining Go routing code until Praxis is production-ready

**Effort:** Low-medium for Phase 1 (refactor within existing codebase). Medium for Phase 2 (Rust implementation of a known interface).

### Option 2: Envoy native MCP filter

Adopt `envoy.filters.http.mcp` and `envoy.filters.http.mcp_router` from Envoy 1.38+. Drop the ext_proc.

**Not pursued.** Violates the Kuadrant policy constraint — Envoy's `mcp_router` routes directly to backend clusters, bypassing HTTPRoutes where policies attach. No per-server AuthPolicy/RateLimitPolicy/TokenRateLimitPolicy. Additionally: Envoy-only investment is misaligned with Praxis direction, `2026-07-28` support timeline in Envoy is unknown, xDS API is marked work-in-progress. See [CONNLINK-1026](https://issues.redhat.com/browse/CONNLINK-1026) for the full evaluation.

## Protocol Transition Policy

**Proposal:** support `2025-11-25` (stateful) until the next MCP spec release after `2026-07-28`, then drop stateful support entirely.

**Rationale:** the MCP spec has a 12-month deprecation window before features can be removed. Aligning our deprecation with the spec's own lifecycle gives clients a clear migration window without us maintaining dual-protocol indefinitely. The `2025-11-25` code path in the routing core is explicitly isolated and disposable.

## Decision

**GA with existing ext_proc router. Invest in `2026-07-28` spec support within Praxis. No further investment in Envoy-native MCP filters.**

### Phased approach

**Phase 1 — October GA: `2026-07-28` support in the Go ext_proc**

Add `2026-07-28` support to the existing Go ext_proc. Refactor the routing logic behind the `Router` interface. Internal branch on `MCP-Protocol-Version`: `2026-07-28` traffic uses header-based routing (+ prefix stripping when configured), `2025-11-25` traffic uses existing body-based routing and session management. One ext_proc, one route, no new infrastructure. The router sources its tool→server mapping from the broker as a cached dataset with `ttlMs`-based refresh, eliminating the in-process broker dependency (see [router-2026-07-28 design](router-2026-07-28/router-2026-07-28-design.md#routing-table-replaces-mcpbroker-interface)).

**Phase 2 — Post-GA: Build the Praxis filter**

Implement the `Router` interface as a Rust Praxis `HttpFilter`. Targets `2026-07-28` only — header routing, `:authority` rewrite, prefix stripping when configured. No session management, no `2025-11-25` support. The Go `Router` interface is the specification for the Rust port. Developed and tested independently — doesn't touch the production deployment.

**Phase 3 — Cutover: Deploy Praxis alongside Go ext_proc**

Deploy Praxis as a second ext_proc. The operator splits the client-facing HTTPRoute by `MCP-Protocol-Version` header and generates an EnvoyFilter with `ExtProcPerRoute` to route each protocol version to the correct ext_proc:

```yaml
# Operator-generated HTTPRoute (two rules, same backend)
rules:
  - matches:
      - path: { value: /mcp }
        headers:
          - name: MCP-Protocol-Version
            value: "2026-07-28"
    backendRefs:
      - name: mcp-broker
        port: 8080
  - matches:
      - path: { value: /mcp }
    backendRefs:
      - name: mcp-broker
        port: 8080
```

```yaml
# Operator-generated EnvoyFilter — two ext_proc filters with per-route disable
http_filters:
  - name: go_ext_proc
    typed_config:
      "@type": .../ExternalProcessor
      grpc_service: { envoy_grpc: { cluster_name: go_ext_proc_cluster } }
  - name: praxis_ext_proc
    typed_config:
      "@type": .../ExternalProcessor
      grpc_service: { envoy_grpc: { cluster_name: praxis_ext_proc_cluster } }

# Route for 2026-07-28: disable Go, enable Praxis
typed_per_filter_config:
  go_ext_proc:
    "@type": .../ExtProcPerRoute
    disabled: true

# Default route: disable Praxis, enable Go
typed_per_filter_config:
  praxis_ext_proc:
    "@type": .../ExtProcPerRoute
    disabled: true
```

Each request hits exactly one ext_proc. `2026-07-28` traffic flows through Praxis, `2025-11-25` stays on Go. The operator manages the routing infrastructure — users create MCPGatewayExtension and MCPServerRegistrations as before, no change to the user-facing API.

Rollback: remove the Praxis filter and collapse back to a single route.

**Phase 4 — Cleanup: Remove Go ext_proc**

Drop `2025-11-25` support. The operator removes the Go ext_proc filter, its route rule, and the `ExtProcPerRoute` config. Single Praxis filter remains. If Praxis replaces Envoy as the gateway, the ext_proc pattern disappears entirely and routing becomes a native filter.

## Open Questions

1. **Praxis production timeline.** Is Praxis on track for post-GA deployment? What's the 0.3.1 → 1.0 path?
2. **Praxis as gateway.** Is Praxis replacing Envoy for AI workloads only, or the full proxy plane? This determines whether ext_proc mode is transitional or long-term.
3. **`2025-11-25` deprecation timeline.** Proposal: drop stateful protocol support at the next MCP spec release after `2026-07-28`. Should we tie it to client adoption metrics instead?
4. **Router-broker mapping interface.** How should the broker expose the tool→server mapping to the router? Options: lightweight HTTP endpoint, shared Redis key, mounted config file with file-watch.

## References

- [CONNLINK-1026](https://issues.redhat.com/browse/CONNLINK-1026) — Envoy 1.38 MCP support evaluation
- [MCP `2026-07-28` draft specification](https://modelcontextprotocol.io/specification/draft)
- [Praxis integration research](https://github.com/kuadrant/research/blob/main/praxis/docs/research/2026-05-20-praxis-integration.md)
- [Praxis open questions](https://github.com/kuadrant/research/blob/main/praxis/docs/research/2026-05-28-praxis-open-questions.md)
- [Current routing design](routing.md)
- [Session management design](session-mgmt.md)
- [Performance constraints](performance.md)
