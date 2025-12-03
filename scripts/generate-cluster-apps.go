// generate-cluster-apps.go
// This script reads app-config.yaml files from apps/workloads/ and apps/infra/,
// and generates cluster-specific directories under apps/clusters/ for ApplicationSet to discover.
//
// Usage: go run scripts/generate-cluster-apps.go
//
// The script is idempotent and safe to run multiple times.
// It removes stale directories for apps that no longer target a cluster.

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

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

func main() {
	// Find the repo root (where apps/ directory exists)
	repoRoot, err := findRepoRoot()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error finding repo root: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Repository root: %s\n", repoRoot)

	// Discover all apps
	apps, err := discoverApps(repoRoot)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error discovering apps: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Discovered %d apps\n", len(apps))

	// Build a map of what should exist: cluster -> type -> app -> true
	expectedStructure := buildExpectedStructure(apps)

	// Generate cluster directories
	clustersDir := filepath.Join(repoRoot, "apps", "clusters")
	if err := generateClusterDirs(clustersDir, apps); err != nil {
		fmt.Fprintf(os.Stderr, "Error generating cluster directories: %v\n", err)
		os.Exit(1)
	}

	// Clean up stale directories
	if err := cleanupStaleDirs(clustersDir, expectedStructure); err != nil {
		fmt.Fprintf(os.Stderr, "Error cleaning up stale directories: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("Done!")
}

// findRepoRoot finds the repository root by looking for the apps/ directory
func findRepoRoot() (string, error) {
	// Start from current directory or the directory containing this script
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}

	// Walk up until we find apps/ directory
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
			content := fmt.Sprintf("# GENERATED - DO NOT EDIT\n# Source: %s/app-config.yaml\n# Run 'go run scripts/generate-cluster-apps.go' to regenerate\n%s", app.SourcePath, string(data))

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
