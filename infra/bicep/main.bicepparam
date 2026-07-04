using './main.bicep'

param location = 'eastus'
param environment = 'dev'
param project = 'contextforge'
param ownerAlias = 'dfernandez'

// Your Azure AD Object ID — grants Key Vault Secrets Officer on deploy.
// Get it with: az ad signed-in-user show --query id -o tsv
param adminObjectId = '38c82ca3-ae43-4af8-b1a3-8eb5755212f0'

// Run: az aks get-versions -l eastus -o table
// 1.35 is the current default in eastus as of 2026-06-29.
param kubernetesVersion = '1.35'

param nodeVmSize = 'Standard_D2s_v7'
// Was 1 — stale from before the Portal-side autoscaler fix (2026-07-02).
// aks.bicep sends `count` unconditionally on every deploy regardless of
// enableAutoScaling, so a mismatched nodeCount here silently resends a
// scale-down command even though enableAutoScaling itself was already fixed.
// Caught 2026-07-04 via `az deployment sub what-if` before a Phase 5
// bicep-deploy: it showed `count: 2 => 1`, live cluster confirmed at 2 nodes
// (`az aks nodepool show`) — this would have reproduced the exact incident
// in the Phase 3/4 log below. Keep equal to minNodeCount going forward.
param nodeCount = 2

// Matches the live node pool config set via Azure Portal on 2026-07-02 after
// a single-node CPU exhaustion incident. Keep this in sync with reality —
// see modules/aks.bicep's enableAutoScaling description.
param enableAutoScaling = true
param minNodeCount = 2
param maxNodeCount = 10
