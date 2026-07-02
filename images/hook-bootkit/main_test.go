package main

import (
	"archive/tar"
	"io"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestParseCmdLineContainerRuntime(t *testing.T) {
	cfg := parseCmdLine([]string{
		"quiet",
		"container_runtime=nerdctl",
		"tink_worker_image=example.com/tink-worker:latest",
		"tink_worker_image_oci=/run/tink-agent-image",
		"tink_worker_image_oci_ref=example.com/source:tink-agent",
	})

	if cfg.containerRuntime != containerRuntimeNerdctl {
		t.Fatalf("container runtime = %q, want %q", cfg.containerRuntime, containerRuntimeNerdctl)
	}
	if cfg.tinkWorkerImageOCI != "/run/tink-agent-image" {
		t.Fatalf("tink worker OCI path = %q, want /run/tink-agent-image", cfg.tinkWorkerImageOCI)
	}
	if cfg.tinkWorkerImageOCIRef != "example.com/source:tink-agent" {
		t.Fatalf("tink worker OCI ref = %q, want example.com/source:tink-agent", cfg.tinkWorkerImageOCIRef)
	}
}

func TestWorkerRuntimeDefaultsToDocker(t *testing.T) {
	t.Setenv("HOOK_BOOTKIT_CONTAINER_RUNTIME", "")

	if got := workerRuntime(tinkWorkerConfig{}); got != containerRuntimeDocker {
		t.Fatalf("workerRuntime() = %q, want %q", got, containerRuntimeDocker)
	}
}

func TestWorkerRuntimeAllowsEnvironmentOverride(t *testing.T) {
	t.Setenv("HOOK_BOOTKIT_CONTAINER_RUNTIME", containerRuntimeNerdctl)

	if got := workerRuntime(tinkWorkerConfig{}); got != containerRuntimeNerdctl {
		t.Fatalf("workerRuntime() = %q, want %q", got, containerRuntimeNerdctl)
	}
}

func TestWorkerRuntimeCmdlineWinsOverEnvironment(t *testing.T) {
	t.Setenv("HOOK_BOOTKIT_CONTAINER_RUNTIME", containerRuntimeDocker)

	cfg := tinkWorkerConfig{containerRuntime: containerRuntimeNerdctl}
	if got := workerRuntime(cfg); got != containerRuntimeNerdctl {
		t.Fatalf("workerRuntime() = %q, want %q", got, containerRuntimeNerdctl)
	}
}

func TestTinkWorkerEnv(t *testing.T) {
	cfg := tinkWorkerConfig{
		registry:              "registry.example.com",
		username:              "user",
		password:              "pass",
		grpcAuthority:         "tink.example.com:42113",
		tinkServerTLS:         "true",
		tinkServerInsecureTLS: "false",
		workerID:              "worker-1",
		httpProxy:             "http://proxy.example.com",
		httpsProxy:            "https://proxy.example.com",
		noProxy:               "localhost,127.0.0.1",
	}

	env := tinkWorkerEnv(cfg)
	for _, expected := range []string{
		"DOCKER_REGISTRY=registry.example.com",
		"REGISTRY_USERNAME=user",
		"REGISTRY_PASSWORD=pass",
		"TINKERBELL_GRPC_AUTHORITY=tink.example.com:42113",
		"TINKERBELL_TLS=true",
		"TINKERBELL_INSECURE_TLS=false",
		"WORKER_ID=worker-1",
		"ID=worker-1",
		"HTTP_PROXY=http://proxy.example.com",
		"HTTPS_PROXY=https://proxy.example.com",
		"NO_PROXY=localhost,127.0.0.1",
	} {
		if !slices.Contains(env, expected) {
			t.Fatalf("expected env %q in %v", expected, env)
		}
	}
}

func TestTinkWorkerEnvForNerdctlUsesContainerdAgentRuntime(t *testing.T) {
	cfg := tinkWorkerConfig{
		containerRuntime: containerRuntimeNerdctl,
		workerID:         "worker-1",
	}

	env := tinkWorkerEnv(cfg)
	for _, expected := range []string{
		"AGENT_RUNTIME=containerd",
		"AGENT_CONTAINERD_NAMESPACE=default",
		"AGENT_CONTAINERD_SOCKET=/run/containerd/containerd.sock",
		"AGENT_CONTAINERD_DATA_ROOT=/var/lib/nerdctl",
	} {
		if !slices.Contains(env, expected) {
			t.Fatalf("expected env %q in %v", expected, env)
		}
	}
}

func TestNerdctlRunArgs(t *testing.T) {
	tempHome := t.TempDir()
	t.Setenv("HOME", tempHome)

	args := nerdctlRunArgs(tinkWorkerConfig{workerID: "worker-1"}, "example.com/tink-worker:latest")

	for _, expected := range []string{
		"run",
		"--detach",
		"--name",
		"tink-worker",
		"--net",
		"host",
		"--privileged",
		"type=bind,src=/var/run/worker,dst=/worker",
		"type=bind,src=/dev,dst=/dev",
		"type=bind,src=/run,dst=/run",
		"type=bind,src=/tmp,dst=/tmp",
		"type=bind,src=/var/lib/containerd,dst=/var/lib/containerd",
		"type=bind,src=/var/lib/nerdctl,dst=/var/lib/nerdctl",
		"WORKER_ID=worker-1",
		"ID=worker-1",
		"example.com/tink-worker:latest",
	} {
		if !slices.Contains(args, expected) {
			t.Fatalf("expected arg %q in %v", expected, args)
		}
	}

	if _, err := os.Stat("/var/run/docker.sock"); err == nil && !slices.Contains(args, "type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock") {
		t.Fatalf("expected Docker socket mount when /var/run/docker.sock exists")
	}
}

func TestTinkWorkerImageOCIPathEnvFallback(t *testing.T) {
	t.Setenv("HOOK_BOOTKIT_TINK_WORKER_IMAGE_OCI", "/run/tink-agent-image")

	got, explicit := tinkWorkerImageOCIPath(tinkWorkerConfig{})
	if got != "/run/tink-agent-image" {
		t.Fatalf("OCI path = %q, want /run/tink-agent-image", got)
	}
	if explicit {
		t.Fatalf("OCI path from env should not be explicit")
	}

	got, explicit = tinkWorkerImageOCIPath(tinkWorkerConfig{tinkWorkerImageOCI: "/cmdline"})
	if got != "/cmdline" {
		t.Fatalf("OCI path = %q, want /cmdline", got)
	}
	if !explicit {
		t.Fatalf("OCI path from cmdline should be explicit")
	}
}

func TestNerdctlStatusIsRunningAllowsInspectWarnings(t *testing.T) {
	output := `WARN[0000] failed to inspect NetNS error="failed to Statfs \"/proc/1633/ns/net\": no such file or directory"
running
`

	if !nerdctlStatusIsRunning(output) {
		t.Fatalf("expected running status in %q", output)
	}
	if nerdctlStatusIsRunning("exited\n") {
		t.Fatalf("did not expect exited status to be treated as running")
	}
}

func TestTarDirectory(t *testing.T) {
	src := t.TempDir()
	if err := os.Mkdir(filepath.Join(src, "blobs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "oci-layout"), []byte(`{"imageLayoutVersion":"1.0.0"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "blobs", "sha256"), []byte("blob"), 0o644); err != nil {
		t.Fatal(err)
	}

	dst := filepath.Join(t.TempDir(), "layout.tar")
	if err := tarDirectory(src, dst); err != nil {
		t.Fatal(err)
	}

	f, err := os.Open(dst)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	found := map[string]bool{}
	tr := tar.NewReader(f)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		found[h.Name] = true
	}
	for _, name := range []string{"blobs/", "blobs/sha256", "oci-layout"} {
		if !found[name] {
			t.Fatalf("tar missing %q, entries: %v", name, found)
		}
	}
}
