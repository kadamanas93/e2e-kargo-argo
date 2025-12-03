// generate-kargo-pipelines.go
// This script reads app-config.yaml files from apps/workloads/ and apps/infra/,
// and generates Kargo resources (Project, Warehouse, Stages) under apps/kargo-configs/.
//
// Usage: go run scripts/generate-kargo-pipelines.go
//
// The script is idempotent and safe to run multiple times.
// It regenerates all Kargo manifests on each run.
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
	Kargo struct {
		Git struct {
			RepoURL string `yaml:"repoURL"`
		} `yaml:"git"`
	} `yaml:"kargo"`
}

func main() {
	// Find the repo root (where apps/ directory exists)
	repoRoot, err := findRepoRoot()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error finding repo root: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Repository root: %s\n", repoRoot)

	// Get Git repo URL (HTTPS for ArgoCD references)
	gitRepoURL, err := getGitRepoURL(repoRoot)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error getting Git repo URL: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Git repo URL (HTTPS): %s\n", gitRepoURL)

	// Get Kargo Git repo URL (SSH for Warehouse subscriptions)
	kargoGitRepoURL := getKargoGitRepoURL(repoRoot, gitRepoURL)
	fmt.Printf("Kargo Git repo URL (SSH): %s\n", kargoGitRepoURL)

	// Discover all apps
	apps, err := discoverApps(repoRoot)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error discovering apps: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Discovered %d apps\n", len(apps))

	// Generate Kargo configs directory
	kargoConfigsDir := filepath.Join(repoRoot, "apps", "kargo-configs")

	// Clean up existing configs
	if err := os.RemoveAll(kargoConfigsDir); err != nil {
		fmt.Fprintf(os.Stderr, "Error cleaning up kargo-configs: %v\n", err)
		os.Exit(1)
	}

	// Generate Kargo resources for each app
	for _, app := range apps {
		fmt.Printf("\nGenerating Kargo configs for %s/%s...\n", app.Type, app.Name)
		if err := generateKargoConfigs(kargoConfigsDir, app, gitRepoURL, kargoGitRepoURL); err != nil {
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

// getKargoGitRepoURL gets the SSH Git URL for Kargo Warehouses
// Falls back to converting HTTPS URL to SSH format if kargo.git.repoURL is not set
func getKargoGitRepoURL(repoRoot string, httpsURL string) string {
	// First try environment variable
	if url := os.Getenv("KARGO_GIT_REPO_URL"); url != "" {
		return url
	}

	// Try values-credentials.yaml kargo.git.repoURL
	credentialsPath := filepath.Join(repoRoot, "values-credentials.yaml")
	if data, err := os.ReadFile(credentialsPath); err == nil {
		var config CredentialsConfig
		if err := yaml.Unmarshal(data, &config); err == nil && config.Kargo.Git.RepoURL != "" {
			// Append repo name to the SSH base URL
			// e.g., git@github.com:user + /repo.git = git@github.com:user/repo.git
			repoName := extractRepoName(httpsURL)
			if repoName != "" {
				return config.Kargo.Git.RepoURL + "/" + repoName
			}
			return config.Kargo.Git.RepoURL
		}
	}

	// Fall back to HTTPS URL (will work if credentials are configured for HTTPS)
	return httpsURL
}

// extractRepoName extracts the repository name from a Git URL
// e.g., "https://github.com/user/repo.git" -> "repo.git"
func extractRepoName(url string) string {
	// Handle URLs like https://github.com/user/repo.git
	parts := strings.Split(url, "/")
	if len(parts) >= 2 {
		return parts[len(parts)-1]
	}
	return ""
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

// generateKargoConfigs generates all Kargo resources for an app
// gitRepoURL: HTTPS URL for ArgoCD references
// kargoGitRepoURL: SSH URL for Warehouse subscriptions
func generateKargoConfigs(kargoConfigsDir string, app AppInfo, gitRepoURL string, kargoGitRepoURL string) error {
	appDir := filepath.Join(kargoConfigsDir, app.Name)
	if err := os.MkdirAll(appDir, 0755); err != nil {
		return fmt.Errorf("creating directory: %w", err)
	}

	// Generate Namespace with Kargo label (allows Kargo to adopt existing namespaces)
	if err := generateNamespace(appDir, app); err != nil {
		return fmt.Errorf("generating namespace: %w", err)
	}

	// Generate Project
	if err := generateProject(appDir, app); err != nil {
		return fmt.Errorf("generating project: %w", err)
	}

	// Generate Warehouse (uses SSH URL for Git subscription)
	if err := generateWarehouse(appDir, app, kargoGitRepoURL); err != nil {
		return fmt.Errorf("generating warehouse: %w", err)
	}

	// Generate Stages (uses HTTPS URL for ArgoCD updates)
	if err := generateStages(appDir, app, gitRepoURL); err != nil {
		return fmt.Errorf("generating stages: %w", err)
	}

	return nil
}

// generateNamespace generates a Namespace resource with Kargo project label
// This allows Kargo to adopt existing namespaces that were created by other apps
func generateNamespace(appDir string, app AppInfo) error {
	content := fmt.Sprintf(`# GENERATED - DO NOT EDIT
# Source: %s/app-config.yaml
# Run 'go run scripts/generate-kargo-pipelines.go' to regenerate
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
# Run 'go run scripts/generate-kargo-pipelines.go' to regenerate
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

// generateWarehouse generates the Kargo Warehouse resource
func generateWarehouse(appDir string, app AppInfo, gitRepoURL string) error {
	content := fmt.Sprintf(`# GENERATED - DO NOT EDIT
# Source: %s/app-config.yaml
# Run 'go run scripts/generate-kargo-pipelines.go' to regenerate
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: %s
  namespace: %s
spec:
  subscriptions:
    - git:
        repoURL: %s
        includePaths:
          - %s/**
`, app.SourcePath, app.Name, app.Name, gitRepoURL, app.SourcePath)

	path := filepath.Join(appDir, "warehouse.yaml")
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		return err
	}
	fmt.Printf("  Generated %s\n", path)
	return nil
}

// generateStages generates all Kargo Stage resources for an app
func generateStages(appDir string, app AppInfo, gitRepoURL string) error {
	// Build ordered list of stages based on target clusters
	stages := buildStageOrder(app.TargetClusters)

	var stagesContent strings.Builder
	stagesContent.WriteString(fmt.Sprintf(`# GENERATED - DO NOT EDIT
# Source: %s/app-config.yaml
# Run 'go run scripts/generate-kargo-pipelines.go' to regenerate
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

// StageInfo holds information about a stage
type StageInfo struct {
	Name     string
	Upstream string // Empty means get from warehouse directly
}

// generateStageYAML generates the YAML for a single stage
func generateStageYAML(app AppInfo, stage StageInfo, gitRepoURL string) string {
	var requestedFreight string
	if stage.Upstream == "" {
		// First stage - get directly from warehouse
		requestedFreight = fmt.Sprintf(`  requestedFreight:
    - origin:
        kind: Warehouse
        name: %s
      sources:
        direct: true`, app.Name)
	} else {
		// Downstream stage - get from upstream stage
		requestedFreight = fmt.Sprintf(`  requestedFreight:
    - origin:
        kind: Warehouse
        name: %s
      sources:
        stages:
          - %s`, app.Name, stage.Upstream)
	}

	return fmt.Sprintf(`apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: %s
  namespace: %s
spec:
  shard: %s
%s
  promotionTemplate:
    spec:
      steps:
        - uses: git-clone
          config:
            repoURL: %s
            checkout:
              - fromFreight: true
                path: ./src
        - uses: argocd-update
          config:
            apps:
              - name: %s
                sources:
                  - repoURL: %s
                    desiredCommitFromStep: ${{ outputs['git-clone'].commit }}
`, stage.Name, app.Name, stage.Name, requestedFreight, gitRepoURL, app.Name, gitRepoURL)
}
