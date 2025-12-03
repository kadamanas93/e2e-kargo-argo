// generate-configs.go
// This script reads app-config.yaml files from apps/workloads/ and apps/infra/,
// and generates:
//   1. Cluster-specific directories under apps/clusters/ for ApplicationSet to discover
//   2. Kargo resources (Project, Warehouse, Stages) under apps/kargo-configs/
//
// Usage: go run scripts/generate-configs.go
//
// The script is idempotent and safe to run multiple times.
// It regenerates all manifests on each run and removes stale directories.
//
// Environment variables:
//   GIT_REPO_URL - Git repository URL (optional, reads from values-credentials.yaml if not set)

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// Promotion order: test → dev → staging → (prod-us, prod-eu, prod-au, infra)
var promotionOrder = []string{"test", "dev", "staging"}
var parallelStages = []string{"prod-us", "prod-eu", "prod-au", "infra"}

// AppConfig represents the structure of app-config.yaml
type AppConfig struct {
	TargetClusters []string `yaml:"targetClusters"`
}

// GeneratedConfig represents the generated app-config.yaml for clusters
type GeneratedConfig struct {
	ChartPath string `yaml:"chartPath"`
}

// AppInfo holds information about a discovered app
type AppInfo struct {
	Name           string
	Type           string // "workloads" or "infra"
	SourcePath     string // e.g., "apps/workloads/simple-echo-server"
	TargetClusters []string
}

// CredentialsConfig represents the structure of values-credentials.yaml
type CredentialsConfig struct {
	GitRepo struct {
		URL string `yaml:"url"`
	} `yaml:"gitRepo"`
}

// StageInfo holds information about a stage
type StageInfo struct {
	Name     string
	Upstream string // Empty means get from warehouse directly
}

func main() {
	// Find the repo root (where apps/ directory exists)
	repoRoot, err := findRepoRoot()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error finding repo root: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Repository root: %s\n", repoRoot)

	// Get Git repo URL (used for Kargo Warehouses)
	gitRepoURL, err := getGitRepoURL(repoRoot)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error getting Git repo URL: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Git repo URL: %s\n", gitRepoURL)

	// Discover all apps
	apps, err := discoverApps(repoRoot)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error discovering apps: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Discovered %d apps\n", len(apps))

	// Generate cluster directories
	fmt.Println("\n=== Generating cluster directories ===")
	clustersDir := filepath.Join(repoRoot, "apps", "clusters")
	expectedStructure := buildExpectedStructure(apps)
	if err := generateClusterDirs(clustersDir, apps); err != nil {
		fmt.Fprintf(os.Stderr, "Error generating cluster directories: %v\n", err)
		os.Exit(1)
	}

	// Clean up stale directories
	if err := cleanupStaleDirs(clustersDir, expectedStructure); err != nil {
		fmt.Fprintf(os.Stderr, "Error cleaning up stale directories: %v\n", err)
		os.Exit(1)
	}

	// Generate Kargo configs
	fmt.Println("\n=== Generating Kargo configs ===")
	kargoConfigsDir := filepath.Join(repoRoot, "apps", "kargo-configs")

	// Clean up existing configs
	if err := os.RemoveAll(kargoConfigsDir); err != nil {
		fmt.Fprintf(os.Stderr, "Error cleaning up kargo-configs: %v\n", err)
		os.Exit(1)
	}

	// Generate Kargo resources for each app
	for _, app := range apps {
		fmt.Printf("\nGenerating Kargo configs for %s/%s...\n", app.Type, app.Name)
		if err := generateKargoConfigs(kargoConfigsDir, app, gitRepoURL); err != nil {
			fmt.Fprintf(os.Stderr, "Error generating Kargo configs for %s: %v\n", app.Name, err)
			os.Exit(1)
		}
	}

	fmt.Println("\nDone!")
}

// findRepoRoot finds the repository root by looking for the apps/ directory
func findRepoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}

	for {
		appsDir := filepath.Join(dir, "apps")
		if info, err := os.Stat(appsDir); err == nil && info.IsDir() {
			return dir, nil
		}

		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("could not find apps/ directory")
		}
		dir = parent
	}
}

// getGitRepoURL gets the Git repository URL from environment or values-credentials.yaml
func getGitRepoURL(repoRoot string) (string, error) {
	// First try environment variable
	if url := os.Getenv("GIT_REPO_URL"); url != "" {
		return url, nil
	}

	// Try values-credentials.yaml
	credentialsPath := filepath.Join(repoRoot, "values-credentials.yaml")
	if data, err := os.ReadFile(credentialsPath); err == nil {
		var config CredentialsConfig
		if err := yaml.Unmarshal(data, &config); err == nil && config.GitRepo.URL != "" {
			return config.GitRepo.URL, nil
		}
	}

	return "", fmt.Errorf("GIT_REPO_URL not set and values-credentials.yaml not found or invalid")
}

// discoverApps finds all apps in apps/workloads/ and apps/infra/
func discoverApps(repoRoot string) ([]AppInfo, error) {
	var apps []AppInfo

	// Discover workloads
	workloadApps, err := discoverAppsInDir(repoRoot, "workloads")
	if err != nil {
		return nil, fmt.Errorf("discovering workloads: %w", err)
	}
	apps = append(apps, workloadApps...)

	// Discover infra apps (excluding argocd itself)
	infraApps, err := discoverAppsInDir(repoRoot, "infra")
	if err != nil {
		return nil, fmt.Errorf("discovering infra apps: %w", err)
	}
	apps = append(apps, infraApps...)

	return apps, nil
}

// discoverAppsInDir discovers apps in a specific type directory (workloads or infra)
func discoverAppsInDir(repoRoot, appType string) ([]AppInfo, error) {
	var apps []AppInfo

	baseDir := filepath.Join(repoRoot, "apps", appType)
	entries, err := os.ReadDir(baseDir)
	if err != nil {
		if os.IsNotExist(err) {
			return apps, nil
		}
		return nil, err
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		appName := entry.Name()

		// Skip argocd - it's the controller, not a managed app
		if appType == "infra" && appName == "argocd" {
			continue
		}

		configPath := filepath.Join(baseDir, appName, "app-config.yaml")
		if _, err := os.Stat(configPath); os.IsNotExist(err) {
			fmt.Printf("  Skipping %s/%s (no app-config.yaml)\n", appType, appName)
			continue
		}

		config, err := readAppConfig(configPath)
		if err != nil {
			return nil, fmt.Errorf("reading %s: %w", configPath, err)
		}

		apps = append(apps, AppInfo{
			Name:           appName,
			Type:           appType,
			SourcePath:     filepath.Join("apps", appType, appName),
			TargetClusters: config.TargetClusters,
		})

		fmt.Printf("  Found %s/%s targeting %v\n", appType, appName, config.TargetClusters)
	}

	return apps, nil
}

// readAppConfig reads and parses an app-config.yaml file
func readAppConfig(path string) (*AppConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var config AppConfig
	if err := yaml.Unmarshal(data, &config); err != nil {
		return nil, err
	}

	return &config, nil
}

// buildExpectedStructure builds a map of cluster -> type -> app -> true
func buildExpectedStructure(apps []AppInfo) map[string]map[string]map[string]bool {
	structure := make(map[string]map[string]map[string]bool)

	for _, app := range apps {
		for _, cluster := range app.TargetClusters {
			if structure[cluster] == nil {
				structure[cluster] = make(map[string]map[string]bool)
			}
			if structure[cluster][app.Type] == nil {
				structure[cluster][app.Type] = make(map[string]bool)
			}
			structure[cluster][app.Type][app.Name] = true
		}
	}

	return structure
}

// generateClusterDirs creates the cluster-specific directories and app-config.yaml files
func generateClusterDirs(clustersDir string, apps []AppInfo) error {
	for _, app := range apps {
		for _, cluster := range app.TargetClusters {
			appDir := filepath.Join(clustersDir, cluster, app.Type, app.Name)

			// Create directory
			if err := os.MkdirAll(appDir, 0755); err != nil {
				return fmt.Errorf("creating %s: %w", appDir, err)
			}

			// Generate app-config.yaml
			configPath := filepath.Join(appDir, "app-config.yaml")
			config := GeneratedConfig{
				ChartPath: app.SourcePath,
			}

			data, err := yaml.Marshal(&config)
			if err != nil {
				return fmt.Errorf("marshaling config: %w", err)
			}

			// Add header comment
			content := fmt.Sprintf("# GENERATED - DO NOT EDIT\n# Source: %s/app-config.yaml\n# Run 'go run scripts/generate-configs.go' to regenerate\n%s", app.SourcePath, string(data))

			if err := os.WriteFile(configPath, []byte(content), 0644); err != nil {
				return fmt.Errorf("writing %s: %w", configPath, err)
			}

			fmt.Printf("  Generated %s\n", configPath)
		}
	}

	return nil
}

// cleanupStaleDirs removes directories that should no longer exist
func cleanupStaleDirs(clustersDir string, expected map[string]map[string]map[string]bool) error {
	// Check if clusters directory exists
	if _, err := os.Stat(clustersDir); os.IsNotExist(err) {
		return nil
	}

	// Get all clusters
	clusterEntries, err := os.ReadDir(clustersDir)
	if err != nil {
		return err
	}

	for _, clusterEntry := range clusterEntries {
		if !clusterEntry.IsDir() {
			continue
		}
		cluster := clusterEntry.Name()

		// Check each type (workloads, infra)
		for _, appType := range []string{"workloads", "infra"} {
			typeDir := filepath.Join(clustersDir, cluster, appType)
			if _, err := os.Stat(typeDir); os.IsNotExist(err) {
				continue
			}

			appEntries, err := os.ReadDir(typeDir)
			if err != nil {
				continue
			}

			for _, appEntry := range appEntries {
				if !appEntry.IsDir() {
					continue
				}
				appName := appEntry.Name()

				// Check if this app should exist for this cluster
				shouldExist := false
				if expected[cluster] != nil && expected[cluster][appType] != nil {
					shouldExist = expected[cluster][appType][appName]
				}

				if !shouldExist {
					appDir := filepath.Join(typeDir, appName)
					fmt.Printf("  Removing stale directory: %s\n", appDir)
					if err := os.RemoveAll(appDir); err != nil {
						return fmt.Errorf("removing %s: %w", appDir, err)
					}
				}
			}

			// Remove empty type directory
			remaining, _ := os.ReadDir(typeDir)
			if len(remaining) == 0 {
				os.Remove(typeDir)
			}
		}

		// Remove empty cluster directory
		clusterDir := filepath.Join(clustersDir, cluster)
		remaining, _ := os.ReadDir(clusterDir)
		if len(remaining) == 0 {
			os.Remove(clusterDir)
		}
	}

	// Print summary of expected structure
	fmt.Println("\nExpected structure:")
	var clusters []string
	for cluster := range expected {
		clusters = append(clusters, cluster)
	}
	sort.Strings(clusters)

	for _, cluster := range clusters {
		types := expected[cluster]
		var typeNames []string
		for t := range types {
			typeNames = append(typeNames, t)
		}
		sort.Strings(typeNames)

		for _, t := range typeNames {
			apps := types[t]
			var appNames []string
			for app := range apps {
				appNames = append(appNames, app)
			}
			sort.Strings(appNames)
			fmt.Printf("  %s/%s: %s\n", cluster, t, strings.Join(appNames, ", "))
		}
	}

	return nil
}

// generateKargoConfigs generates all Kargo resources for an app
func generateKargoConfigs(kargoConfigsDir string, app AppInfo, gitRepoURL string) error {
	appDir := filepath.Join(kargoConfigsDir, app.Name)
	if err := os.MkdirAll(appDir, 0755); err != nil {
		return fmt.Errorf("creating directory: %w", err)
	}

	// Build stage order for this app
	stages := buildStageOrder(app.TargetClusters)

	// Generate Namespace with Kargo label (allows Kargo to adopt existing namespaces)
	if err := generateNamespace(appDir, app); err != nil {
		return fmt.Errorf("generating namespace: %w", err)
	}

	// Generate Project
	if err := generateProject(appDir, app); err != nil {
		return fmt.Errorf("generating project: %w", err)
	}

	// Generate ProjectConfig with promotion policies
	if err := generateProjectConfig(appDir, app, stages); err != nil {
		return fmt.Errorf("generating project config: %w", err)
	}

	// Generate Warehouse
	if err := generateWarehouse(appDir, app, gitRepoURL); err != nil {
		return fmt.Errorf("generating warehouse: %w", err)
	}

	// Generate Stages
	if err := generateStagesFromList(appDir, app, stages, gitRepoURL); err != nil {
		return fmt.Errorf("generating stages: %w", err)
	}

	return nil
}

// generateNamespace generates a Namespace resource with Kargo project label
// This allows Kargo to adopt existing namespaces that were created by other apps
func generateNamespace(appDir string, app AppInfo) error {
	content := fmt.Sprintf(`# GENERATED - DO NOT EDIT
# Source: %s/app-config.yaml
# Run 'go run scripts/generate-configs.go' to regenerate
#
# This namespace resource labels the namespace for Kargo project adoption.
# If the namespace already exists (e.g., created by the app deployment),
# this will add the required label so Kargo can manage it as a Project.
apiVersion: v1
kind: Namespace
metadata:
  name: %s
  labels:
    kargo.akuity.io/project: "true"
`, app.SourcePath, app.Name)

	path := filepath.Join(appDir, "namespace.yaml")
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		return err
	}
	fmt.Printf("  Generated %s\n", path)
	return nil
}

// generateProject generates the Kargo Project resource
func generateProject(appDir string, app AppInfo) error {
	content := fmt.Sprintf(`# GENERATED - DO NOT EDIT
# Source: %s/app-config.yaml
# Run 'go run scripts/generate-configs.go' to regenerate
apiVersion: kargo.akuity.io/v1alpha1
kind: Project
metadata:
  name: %s
`, app.SourcePath, app.Name)

	path := filepath.Join(appDir, "project.yaml")
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		return err
	}
	fmt.Printf("  Generated %s\n", path)
	return nil
}

// generateProjectConfig generates the Kargo ProjectConfig resource
// This enables auto-promotion for all stages except test
func generateProjectConfig(appDir string, app AppInfo, stages []StageInfo) error {
	// Build promotion policies - enable auto-promotion for all stages except test
	var policies strings.Builder
	for _, stage := range stages {
		if stage.Name != "test" {
			policies.WriteString(fmt.Sprintf(`    - stageSelector:
        name: %s
      autoPromotionEnabled: true
`, stage.Name))
		}
	}

	content := fmt.Sprintf(`# GENERATED - DO NOT EDIT
# Source: %s/app-config.yaml
# Run 'go run scripts/generate-configs.go' to regenerate
#
# ProjectConfig enables auto-promotion for all stages except test.
# test stage requires manual promotion to initiate the pipeline.
apiVersion: kargo.akuity.io/v1alpha1
kind: ProjectConfig
metadata:
  name: %s
  namespace: %s
spec:
  promotionPolicies:
%s`, app.SourcePath, app.Name, app.Name, policies.String())

	path := filepath.Join(appDir, "project-config.yaml")
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		return err
	}
	fmt.Printf("  Generated %s\n", path)
	return nil
}

// generateWarehouse generates the Kargo Warehouse resource
func generateWarehouse(appDir string, app AppInfo, gitRepoURL string) error {
	content := fmt.Sprintf(`# GENERATED - DO NOT EDIT
# Source: %s/app-config.yaml
# Run 'go run scripts/generate-configs.go' to regenerate
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: %s
  namespace: %s
spec:
  subscriptions:
    - git:
        repoURL: %s
        branch: main
        includePaths:
          - %s
`, app.SourcePath, app.Name, app.Name, gitRepoURL, app.SourcePath)

	path := filepath.Join(appDir, "warehouse.yaml")
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		return err
	}
	fmt.Printf("  Generated %s\n", path)
	return nil
}

// generateStages generates all Kargo Stage resources for an app
func generateStagesFromList(appDir string, app AppInfo, stages []StageInfo, gitRepoURL string) error {
	var stagesContent strings.Builder
	stagesContent.WriteString(fmt.Sprintf(`# GENERATED - DO NOT EDIT
# Source: %s/app-config.yaml
# Run 'go run scripts/generate-configs.go' to regenerate
#
# Promotion flow: test → dev → staging → (prod-us, prod-eu, prod-au, infra)
`, app.SourcePath))

	for i, stage := range stages {
		if i > 0 {
			stagesContent.WriteString("---\n")
		}
		stageYAML := generateStageYAML(app, stage, gitRepoURL)
		stagesContent.WriteString(stageYAML)
	}

	path := filepath.Join(appDir, "stages.yaml")
	if err := os.WriteFile(path, []byte(stagesContent.String()), 0644); err != nil {
		return err
	}
	fmt.Printf("  Generated %s\n", path)
	return nil
}

// buildStageOrder returns the ordered list of stages for the app based on target clusters
func buildStageOrder(targetClusters []string) []StageInfo {
	var stages []StageInfo
	clusterSet := make(map[string]bool)
	for _, c := range targetClusters {
		clusterSet[c] = true
	}

	// Add sequential stages in order
	for i, cluster := range promotionOrder {
		if clusterSet[cluster] {
			var upstream string
			if i == 0 {
				upstream = "" // First stage gets from warehouse
			} else {
				// Find the previous stage that exists in target clusters
				for j := i - 1; j >= 0; j-- {
					if clusterSet[promotionOrder[j]] {
						upstream = promotionOrder[j]
						break
					}
				}
			}
			stages = append(stages, StageInfo{
				Name:     cluster,
				Upstream: upstream,
			})
		}
	}

	// Add parallel stages (all get from staging or the last sequential stage)
	lastSequential := ""
	for i := len(promotionOrder) - 1; i >= 0; i-- {
		if clusterSet[promotionOrder[i]] {
			lastSequential = promotionOrder[i]
			break
		}
	}

	// Sort parallel stages for consistent output
	var parallelToAdd []string
	for _, cluster := range parallelStages {
		if clusterSet[cluster] {
			parallelToAdd = append(parallelToAdd, cluster)
		}
	}
	sort.Strings(parallelToAdd)

	for _, cluster := range parallelToAdd {
		stages = append(stages, StageInfo{
			Name:     cluster,
			Upstream: lastSequential,
		})
	}

	return stages
}

// generateStageYAML generates the YAML for a single stage
func generateStageYAML(app AppInfo, stage StageInfo, gitRepoURL string) string {
	var requestedFreight string

	if stage.Upstream == "" {
		// First stage - get directly from warehouse, no auto-promotion
		requestedFreight = fmt.Sprintf(`  requestedFreight:
    - origin:
        kind: Warehouse
        name: %s
      sources:
        direct: true`, app.Name)
	} else {
		// Downstream stage - get from upstream stage with MatchUpstream auto-promotion
		requestedFreight = fmt.Sprintf(`  requestedFreight:
    - origin:
        kind: Warehouse
        name: %s
      sources:
        stages:
          - %s
        autoPromotionOptions:
          selectionPolicy: MatchUpstream`, app.Name, stage.Upstream)
	}

	// Infra stage uses default shard (no shard specified)
	var shardField string
	if stage.Name == "infra" {
		shardField = ""
	} else {
		shardField = fmt.Sprintf("  shard: %s\n", stage.Name)
	}

	return fmt.Sprintf(`apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: %s
  namespace: %s
spec:
%s%s
  promotionTemplate:
    spec:
      steps:
        - uses: argocd-update
          config:
            apps:
              - name: %s
`, stage.Name, app.Name, shardField, requestedFreight, app.Name)
}
