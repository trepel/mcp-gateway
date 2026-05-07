#!/bin/bash
set -e

# backfill-triage.sh: Fixes issues missing triage labels or having duplicate priority labels.
# Requires GitHub CLI (gh) and jq.

# Fetch all open issues
echo "Fetching open issues..."
issues=$(gh issue list --state open --limit 1000 --json number,labels,milestone)

echo "$issues" | jq -c '.[]' | while read -r issue; do
  number=$(echo "$issue" | jq -r '.number')
  milestone=$(echo "$issue" | jq -r '.milestone')
  # Extract label names into a space-separated string
  labels_str=$(echo "$issue" | jq -r '.labels[].name')
  # Convert to array for easier processing
  read -ra labels <<< "$labels_str"
  
  echo "Processing issue #$number"
  
  labels_to_add=()
  labels_to_remove=()
  
  has_milestone=false
  if [ "$milestone" != "null" ]; then
    has_milestone=true
  fi
  
  has_priority_label=false
  priority_labels=()
  triage_labels=()
  
  for label in "${labels[@]}"; do
    if [[ $label == triage/* ]]; then
      triage_labels+=("$label")
    fi
    if [[ $label == priority/* ]]; then
      has_priority_label=true
      priority_labels+=("$label")
    fi
  done
  
  if [ "$has_milestone" = false ]; then
    # Rule 1: No milestone -> remove triage/accepted and all priority labels
    if [[ " ${labels[*]} " =~ " triage/accepted " ]]; then
      labels_to_remove+=("triage/accepted")
    fi
    
    for pl in "${priority_labels[@]}"; do
      labels_to_remove+=("$pl")
    done
    
    # Ensure triage/needs-triage if no other triage label exists
    other_triage=false
    for tl in "${triage_labels[@]}"; do
      if [ "$tl" != "triage/accepted" ]; then
        other_triage=true
      fi
    done
    
    if [ "$other_triage" = false ]; then
      if [[ ! " ${labels[*]} " =~ " triage/needs-triage " ]]; then
        labels_to_add+=("triage/needs-triage")
      fi
    elif [[ " ${labels[*]} " =~ " triage/needs-triage " ]]; then
      # if another triage label exists, remove triage/needs-triage
      labels_to_remove+=("triage/needs-triage")
    fi
  else
    # Rule 2: Has milestone -> ensure triage/accepted, remove other triage, ensure priority
    if [[ ! " ${labels[*]} " =~ " triage/accepted " ]]; then
      labels_to_add+=("triage/accepted")
    fi
    
    for tl in "${triage_labels[@]}"; do
      if [ "$tl" != "triage/accepted" ]; then
        labels_to_remove+=("$tl")
      fi
    done
    
    if [ "$has_priority_label" = false ]; then
      labels_to_add+=("priority/normal")
    fi
  fi
  
  # Rule 4: Enforce single priority label
  if [ ${#priority_labels[@]} -gt 1 ]; then
    # Keep priority/normal if present, else keep the first one
    preferred_priority=""
    for pl in "${priority_labels[@]}"; do
       if [ "$pl" == "priority/normal" ]; then
         preferred_priority="priority/normal"
         break
       fi
    done
    if [ -z "$preferred_priority" ]; then
      preferred_priority="${priority_labels[0]}"
    fi
    
    for pl in "${priority_labels[@]}"; do
      if [ "$pl" != "$preferred_priority" ]; then
        labels_to_remove+=("$pl")
      fi
    done
  fi

  # Apply additions
  for la in "${labels_to_add[@]}"; do
    echo "  Adding label: $la"
    gh issue edit "$number" --add-label "$la" || echo "  Warning: Failed to add label $la"
  done
  
  # Apply removals
  for lr in "${labels_to_remove[@]}"; do
    # Only remove if it's currently present
    if [[ " ${labels[*]} " =~ " $lr " ]]; then
      echo "  Removing label: $lr"
      gh issue edit "$number" --remove-label "$lr" || echo "  Warning: Failed to remove label $lr"
    fi
  done
done

echo "Backfill complete."
