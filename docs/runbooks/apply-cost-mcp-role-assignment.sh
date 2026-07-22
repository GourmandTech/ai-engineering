#!/usr/bin/env bash
set -euo pipefail

az role assignment create \
  --assignee 45da7aa5-98df-4a4a-a69f-c03a753259d7 \
  --role "Cost MCP Role-Assignment Grantor (custom, Phase 6.2 deploy)" \
  --scope /subscriptions/b5d1ee02-5ad0-44d6-9b14-80e38c714404 \
  --condition-version 2.0 \
  --condition "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {72fafb9e-0641-4937-9268-a91bfd8191a3}))"
