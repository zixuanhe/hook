package main

import (
	"archive/tar"
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/cenkalti/backoff/v4"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/image"
	"github.com/docker/docker/api/types/mount"
	"github.com/docker/docker/api/types/registry"
	"github.com/docker/docker/client"
	"github.com/go-logr/logr"
	"github.com/go-logr/zerologr"
	"github.com/rs/zerolog"
)

type tinkWorkerConfig struct {
	// Registry configuration
	registry string
	username string
	password string

	// Tink Server GRPC address:port
	grpcAuthority string

	// Worker ID
	workerID string

	// tinkWorkerImage is the Tink worker image location.
	tinkWorkerImage string

	// tinkWorkerImageOCI is an optional OCI image layout or image archive to
	// import before starting the worker with containerd/nerdctl.
	tinkWorkerImageOCI string

	// tinkWorkerImageOCIRef is the image reference expected inside the imported
	// OCI image layout. When set, BootKit tags it as tinkWorkerImage after load.
	tinkWorkerImageOCIRef string

	// tinkServerTLS is whether or not to use TLS for tink-server communication.
	tinkServerTLS string

	// tinkServerInsecureTLS is whether or not to use insecure TLS for tink-server communication; only applies is TLS itself is on
	tinkServerInsecureTLS string

	httpProxy  string
	httpsProxy string
	noProxy    string

	containerRuntime string
}

const (
	containerRuntimeDocker  = "docker"
	containerRuntimeNerdctl = "nerdctl"

	embeddedLoong64TinkAgentImage = "127.0.0.1/embedded/tink-agent:loong64"
	nerdctlBin                    = "/usr/bin/nerdctl"
)

func main() {
	ctx, done := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGHUP, syscall.SIGTERM)
	defer done()
	log := defaultLogger("debug")
	log.Info("starting BootKit: the tink-worker bootstrapper")

	for {
		if errors.Is(ctx.Err(), context.Canceled) {
			log.Info("context cancellation received, exiting")
			return
		}
		if err := run(ctx, log); err != nil {
			log.Error(err, "bootstrapping tink-worker failed")
			log.Info("will retry in 5 seconds")
			time.Sleep(5 * time.Second)
			continue
		}
		break
	}
	log.Info("BootKit: the tink-worker bootstrapper finished")
}

// TODO(jacobweinstock): clean up func run().
// 1. read /proc/cmdline
// 2. parse and populate tinkConfig from contents of /proc/cmdline
// 3. do validation/sanitization on tinkConfig
// 4. setup docker client
// 4. configure any registry auth
// 5. pull tink-worker image
// 6. remove any existing tink-worker container
// 7. setup tink-worker container config
// 8. create tink-worker container
// 9. start tink-worker container
// 10. check that the tink-worker container is running

func run(ctx context.Context, log logr.Logger) error {
	content, err := os.ReadFile("/proc/cmdline")
	if err != nil {
		return err
	}
	cmdLines := strings.Split(string(content), " ")
	cfg := parseCmdLine(cmdLines)
	// Generate the path to the tink-worker
	var imageName string
	if cfg.registry != "" {
		imageName = path.Join(cfg.registry, "tink-worker:latest")
	}
	if cfg.tinkWorkerImage != "" {
		imageName = cfg.tinkWorkerImage
	}
	if imageName == "" {
		return fmt.Errorf("cannot pull image for tink-worker, 'docker_registry' and/or 'tink_worker_image' NOT specified in /proc/cmdline")
	}

	os.Setenv("HTTP_PROXY", cfg.httpProxy)
	os.Setenv("HTTPS_PROXY", cfg.httpsProxy)
	os.Setenv("NO_PROXY", cfg.noProxy)

	switch workerRuntime(cfg) {
	case containerRuntimeDocker:
		return runWithDocker(ctx, log, cfg, imageName)
	case containerRuntimeNerdctl:
		return runWithNerdctl(ctx, log, cfg, imageName)
	default:
		return fmt.Errorf("unsupported container runtime %q", workerRuntime(cfg))
	}
}

func runWithDocker(ctx context.Context, log logr.Logger, cfg tinkWorkerConfig, imageName string) error {
	// Give time for Docker to start
	// Alternatively we watch for the socket being created
	log.Info("setting up the Docker client")

	// Create Docker client with API (socket)
	cli, err := client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
	if err != nil {
		return err
	}

	log.Info("Pulling image", "imageName", imageName)
	authConfig := registry.AuthConfig{
		Username: cfg.username,
		Password: strings.TrimSuffix(cfg.password, "\n"),
	}

	encodedJSON, err := json.Marshal(authConfig)
	if err != nil {
		return err
	}

	authStr := base64.URLEncoding.EncodeToString(encodedJSON)

	pullOpts := image.PullOptions{}
	if useAuth(imageName, cfg.registry) {
		pullOpts.RegistryAuth = authStr
	}
	var out io.ReadCloser
	imagePullOperation := func() error {
		// with embedded images, the tink worker could potentially already exist
		// in the local Docker image cache. And the image name could be something
		// unreachable via the network (for example: 127.0.0.1/embedded/tink-worker).
		// Because of this we check if the image already exists and don't return an
		// error if the image does not exist and the pull fails.
		var imageExists bool
		if _, _, err := cli.ImageInspectWithRaw(ctx, imageName); err == nil {
			imageExists = true
		}
		out, err = cli.ImagePull(ctx, imageName, pullOpts)
		if err != nil && !imageExists {
			log.Error(err, "image pull failure", "imageName", imageName)
			return err
		}
		return nil
	}
	if err := backoff.Retry(imagePullOperation, backoff.NewExponentialBackOff()); err != nil {
		return err
	}

	if out != nil {
		buf := bufio.NewScanner(out)
		for buf.Scan() {
			structured := make(map[string]interface{})
			if err := json.Unmarshal(buf.Bytes(), &structured); err != nil {
				log.Info("image pull logs", "output", buf.Text())
			} else {
				log.Info("image pull logs", "logs", structured)
			}

		}
		if err := out.Close(); err != nil {
			log.Error(err, "closing image pull logs failed")
		}
	}

	log.Info("Removing any existing tink-worker container")
	if err := removeTinkWorkerContainer(ctx, cli); err != nil {
		return fmt.Errorf("failed to remove existing tink-worker container: %w", err)
	}

	log.Info("Creating tink-worker container")
	tinkContainer := &container.Config{
		Image:        imageName,
		Env:          tinkWorkerEnv(cfg),
		AttachStdout: true,
		AttachStderr: true,
	}

	tinkHostConfig := &container.HostConfig{
		Mounts: []mount.Mount{
			{
				Type:   mount.TypeBind,
				Source: "/worker",
				Target: "/worker",
			},
			{
				Type:   mount.TypeBind,
				Source: "/var/run/docker.sock",
				Target: "/var/run/docker.sock",
			},
			{
				Type:   mount.TypeBind,
				Source: "/dev",
				Target: "/dev",
			},
			{
				Type:   mount.TypeBind,
				Source: "/host_root/run",
				Target: "/run",
			},
		},
		NetworkMode: "host",
		Privileged:  true,
	}
	resp, err := cli.ContainerCreate(ctx, tinkContainer, tinkHostConfig, nil, nil, "tink-worker")
	if err != nil {
		return fmt.Errorf("creating tink-worker container failed: %w", err)
	}

	log.Info("Starting tink-worker container")
	if err := cli.ContainerStart(ctx, resp.ID, container.StartOptions{}); err != nil {
		return fmt.Errorf("starting tink-worker container failed: %w", err)
	}

	time.Sleep(time.Second * 3)
	// if tink-worker is not running return error so we try again
	if err := checkContainerRunning(ctx, cli, resp.ID); err != nil {
		return fmt.Errorf("checking if tink-worker container is running failed: %w", err)
	}

	return nil
}

func runWithNerdctl(ctx context.Context, log logr.Logger, cfg tinkWorkerConfig, imageName string) error {
	log.Info("setting up the nerdctl client")

	if err := prepareNerdctlRuntime(); err != nil {
		return err
	}

	preloaded, err := preloadNerdctlImage(ctx, log, cfg, imageName)
	if err != nil {
		return err
	}

	if useAuth(imageName, cfg.registry) && cfg.username != "" {
		login := nerdctlCommand(ctx, "login", cfg.registry, "--username", cfg.username, "--password-stdin")
		login.Stdin = strings.NewReader(strings.TrimSuffix(cfg.password, "\n"))
		if output, err := login.CombinedOutput(); err != nil {
			return fmt.Errorf("nerdctl login failed: %w: %s", err, strings.TrimSpace(string(output)))
		}
	}

	log.Info("Pulling image", "imageName", imageName)
	imagePullOperation := func() error {
		imageExists := nerdctlSucceeds(ctx, "image", "inspect", imageName)
		if preloaded && imageExists {
			log.Info("Skipping image pull; using embedded worker image", "imageName", imageName)
			return nil
		}
		if output, err := nerdctlCommand(ctx, "pull", imageName).CombinedOutput(); err != nil && !imageExists {
			log.Error(err, "image pull failure", "imageName", imageName, "output", strings.TrimSpace(string(output)))
			return err
		}
		return nil
	}
	if err := backoff.Retry(imagePullOperation, backoff.NewExponentialBackOff()); err != nil {
		return err
	}

	log.Info("Removing any existing tink-worker container")
	if nerdctlSucceeds(ctx, "container", "inspect", "tink-worker") {
		if output, err := nerdctlCommand(ctx, "rm", "-f", "tink-worker").CombinedOutput(); err != nil {
			return fmt.Errorf("removing existing tink-worker container failed: %w: %s", err, strings.TrimSpace(string(output)))
		}
	}

	log.Info("Creating tink-worker container")
	runArgs := nerdctlRunArgs(cfg, imageName)
	output, err := nerdctlCommand(ctx, runArgs...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("starting tink-worker container failed: %w: %s", err, strings.TrimSpace(string(output)))
	}

	checkRunning := func() error {
		return checkNerdctlContainerRunning(ctx, "tink-worker")
	}
	if err := backoff.Retry(checkRunning, backoff.WithMaxRetries(backoff.NewConstantBackOff(time.Second), 20)); err != nil {
		return err
	}

	return nil
}

func tinkWorkerEnv(cfg tinkWorkerConfig) []string {
	env := []string{
		fmt.Sprintf("DOCKER_REGISTRY=%s", cfg.registry),
		fmt.Sprintf("REGISTRY_USERNAME=%s", cfg.username),
		fmt.Sprintf("REGISTRY_PASSWORD=%s", cfg.password),
		fmt.Sprintf("TINKERBELL_GRPC_AUTHORITY=%s", cfg.grpcAuthority),
		fmt.Sprintf("TINKERBELL_TLS=%s", cfg.tinkServerTLS),
		fmt.Sprintf("TINKERBELL_INSECURE_TLS=%s", cfg.tinkServerInsecureTLS),
		fmt.Sprintf("WORKER_ID=%s", cfg.workerID),
		fmt.Sprintf("ID=%s", cfg.workerID),
		fmt.Sprintf("HTTP_PROXY=%s", cfg.httpProxy),
		fmt.Sprintf("HTTPS_PROXY=%s", cfg.httpsProxy),
		fmt.Sprintf("NO_PROXY=%s", cfg.noProxy),
	}
	if workerRuntime(cfg) == containerRuntimeNerdctl {
		env = append(env,
			"AGENT_RUNTIME=containerd",
			"AGENT_CONTAINERD_NAMESPACE=default",
			"AGENT_CONTAINERD_SOCKET=/run/containerd/containerd.sock",
			"AGENT_CONTAINERD_DATA_ROOT=/var/lib/nerdctl",
		)
	}
	return env
}

func nerdctlRunArgs(cfg tinkWorkerConfig, imageName string) []string {
	args := []string{
		"run",
		"--detach",
		"--name", "tink-worker",
		"--net", "host",
		"--privileged",
		"--mount", "type=bind,src=/var/run/worker,dst=/worker",
		"--mount", "type=bind,src=/dev,dst=/dev",
		"--mount", "type=bind,src=/run,dst=/run",
		"--mount", "type=bind,src=/tmp,dst=/tmp",
		"--mount", "type=bind,src=/var/lib/containerd,dst=/var/lib/containerd",
		"--mount", "type=bind,src=/var/lib/nerdctl,dst=/var/lib/nerdctl",
	}

	if _, err := os.Stat("/var/run/docker.sock"); err == nil {
		args = append(args, "--mount", "type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock")
	}
	if _, err := os.Stat("/run/containerd/containerd.sock"); err == nil {
		args = append(args, "--mount", "type=bind,src=/run/containerd/containerd.sock,dst=/run/containerd/containerd.sock")
	}

	for _, env := range tinkWorkerEnv(cfg) {
		args = append(args, "-e", env)
	}

	args = append(args, imageName)
	return args
}

func commandSucceeds(ctx context.Context, name string, args ...string) bool {
	return exec.CommandContext(ctx, name, args...).Run() == nil
}

func nerdctlCommand(ctx context.Context, args ...string) *exec.Cmd {
	var cmd *exec.Cmd
	if _, err := os.Stat(nerdctlBin); err == nil {
		cmd = exec.CommandContext(ctx, nerdctlBin, args...)
	} else {
		cmd = exec.CommandContext(ctx, "nerdctl", args...)
	}
	cmd.Env = append(os.Environ(), "NETCONFPATH=/run/cni/net.d")
	return cmd
}

func nerdctlSucceeds(ctx context.Context, args ...string) bool {
	return nerdctlCommand(ctx, args...).Run() == nil
}

func checkNerdctlContainerRunning(ctx context.Context, name string) error {
	output, err := nerdctlCommand(ctx, "inspect", "-f", "{{.State.Status}}", name).CombinedOutput()
	if err != nil {
		return fmt.Errorf("checking if %s container is running failed: %w: %s", name, err, strings.TrimSpace(string(output)))
	}
	if nerdctlStatusIsRunning(string(output)) {
		return nil
	}
	return fmt.Errorf("%s container is not running: %s", name, strings.TrimSpace(string(output)))
}

func nerdctlStatusIsRunning(output string) bool {
	for _, line := range strings.Split(output, "\n") {
		if strings.TrimSpace(line) == "running" {
			return true
		}
	}
	return false
}

func prepareNerdctlRuntime() error {
	for _, dir := range []string{"/tmp", "/var/lib/nerdctl", "/run/cni/net.d"} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("create nerdctl runtime directory %q failed: %w", dir, err)
		}
	}
	return nil
}

func preloadNerdctlImage(ctx context.Context, log logr.Logger, cfg tinkWorkerConfig, imageName string) (bool, error) {
	ociPath, explicit := tinkWorkerImageOCIPath(cfg)
	if ociPath == "" {
		return false, nil
	}
	if !explicit && imageName != embeddedLoong64TinkAgentImage {
		log.Info("skipping embedded tink-agent image import because worker image was overridden", "imageName", imageName)
		return false, nil
	}
	if nerdctlSucceeds(ctx, "image", "inspect", imageName) {
		return true, nil
	}
	info, err := os.Stat(ociPath)
	if err != nil {
		return false, fmt.Errorf("stat embedded worker image %q failed: %w", ociPath, err)
	}

	loadPath := ociPath
	var cleanupLoadPath func()
	if info.IsDir() {
		tmp, err := os.CreateTemp("/run", "tink-worker-image-*.tar")
		if err != nil {
			return false, fmt.Errorf("create temporary OCI archive failed: %w", err)
		}
		loadPath = tmp.Name()
		if err := tmp.Close(); err != nil {
			return false, fmt.Errorf("close temporary OCI archive failed: %w", err)
		}
		cleanupLoadPath = func() { os.Remove(loadPath) }
		if err := tarDirectory(ociPath, loadPath); err != nil {
			return false, fmt.Errorf("archive embedded worker OCI image layout failed: %w", err)
		}
	}
	if cleanupLoadPath != nil {
		defer cleanupLoadPath()
	}

	log.Info("Importing embedded worker image", "path", ociPath, "imageName", imageName)
	if output, err := nerdctlCommand(ctx, "load", "-i", loadPath).CombinedOutput(); err != nil {
		return false, fmt.Errorf("nerdctl load embedded worker image failed: %w: %s", err, strings.TrimSpace(string(output)))
	}

	ociRef := tinkWorkerImageOCIRef(cfg)
	if ociRef != "" && ociRef != imageName {
		if output, err := nerdctlCommand(ctx, "tag", ociRef, imageName).CombinedOutput(); err != nil {
			return false, fmt.Errorf("tag embedded worker image %q as %q failed: %w: %s", ociRef, imageName, err, strings.TrimSpace(string(output)))
		}
	}

	return true, nil
}

func tinkWorkerImageOCIPath(cfg tinkWorkerConfig) (string, bool) {
	if cfg.tinkWorkerImageOCI != "" {
		return cfg.tinkWorkerImageOCI, true
	}
	return os.Getenv("HOOK_BOOTKIT_TINK_WORKER_IMAGE_OCI"), false
}

func tinkWorkerImageOCIRef(cfg tinkWorkerConfig) string {
	if cfg.tinkWorkerImageOCIRef != "" {
		return cfg.tinkWorkerImageOCIRef
	}
	return os.Getenv("HOOK_BOOTKIT_TINK_WORKER_IMAGE_OCI_REF")
}

func tarDirectory(srcDir, dstTar string) error {
	out, err := os.Create(dstTar)
	if err != nil {
		return err
	}
	defer out.Close()

	tw := tar.NewWriter(out)
	defer tw.Close()

	return filepath.WalkDir(srcDir, func(p string, d os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(srcDir, p)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		header, err := tar.FileInfoHeader(info, "")
		if err != nil {
			return err
		}
		header.Name = filepath.ToSlash(rel)
		if d.IsDir() {
			header.Name += "/"
		}
		if err := tw.WriteHeader(header); err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		in, err := os.Open(p)
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(tw, in)
		closeErr := in.Close()
		if copyErr != nil {
			return copyErr
		}
		return closeErr
	})
}

// checkContainerRunning checks if the tink-worker container is running.
func checkContainerRunning(ctx context.Context, cli *client.Client, containerID string) error {
	inspect, err := cli.ContainerInspect(ctx, containerID)
	if err != nil {
		return err
	}
	if !inspect.State.Running {
		return fmt.Errorf("tink-worker container is not running")
	}
	return nil
}

// removeTinkWorkerContainer removes the tink-worker container if it exists.
func removeTinkWorkerContainer(ctx context.Context, cli *client.Client) error {
	cs, err := cli.ContainerList(ctx, container.ListOptions{All: true})
	if err != nil {
		return fmt.Errorf("listing containers, in order to find an existing tink-worker container, failed: %w", err)
	}
	for _, c := range cs {
		for _, n := range c.Names {
			if n == "/tink-worker" {
				if err := cli.ContainerRemove(ctx, c.ID, container.RemoveOptions{Force: true}); err != nil {
					return fmt.Errorf("removing existing tink-worker container failed: %w", err)
				}
			}
		}
	}
	return nil
}

// parseCmdLine will parse the command line.
// These values follow what Boots sends to the auto.ipxe Script.
// https://github.com/tinkerbell/boots/blob/main/ipxe/hook.go
func parseCmdLine(cmdLines []string) (cfg tinkWorkerConfig) {
	for i := range cmdLines {
		cmdLine := strings.SplitN(strings.TrimSpace(cmdLines[i]), "=", 2)
		if len(cmdLine) != 2 {
			continue
		}

		switch cmd := cmdLine[0]; cmd {
		case "docker_registry":
			cfg.registry = cmdLine[1]
		case "registry_username":
			cfg.username = cmdLine[1]
		case "registry_password":
			cfg.password = cmdLine[1]
		case "grpc_authority":
			cfg.grpcAuthority = cmdLine[1]
		case "worker_id":
			cfg.workerID = cmdLine[1]
		case "tink_worker_image":
			cfg.tinkWorkerImage = cmdLine[1]
		case "tink_worker_image_oci":
			cfg.tinkWorkerImageOCI = cmdLine[1]
		case "tink_worker_image_oci_ref":
			cfg.tinkWorkerImageOCIRef = cmdLine[1]
		case "tinkerbell_tls":
			cfg.tinkServerTLS = cmdLine[1]
		case "tinkerbell_insecure_tls":
			cfg.tinkServerInsecureTLS = cmdLine[1]
		case "HTTP_PROXY":
			cfg.httpProxy = cmdLine[1]
		case "HTTPS_PROXY":
			cfg.httpsProxy = cmdLine[1]
		case "NO_PROXY":
			cfg.noProxy = cmdLine[1]
		case "container_runtime":
			cfg.containerRuntime = cmdLine[1]
		}
	}
	return cfg
}

func workerRuntime(cfg tinkWorkerConfig) string {
	if cfg.containerRuntime != "" {
		return cfg.containerRuntime
	}
	if runtime := os.Getenv("HOOK_BOOTKIT_CONTAINER_RUNTIME"); runtime != "" {
		return runtime
	}
	return containerRuntimeDocker
}

// defaultLogger is a zerolog logr implementation.
func defaultLogger(level string) logr.Logger {
	zl := zerolog.New(os.Stdout)
	zl = zl.With().Caller().Timestamp().Logger()
	var l zerolog.Level
	switch level {
	case "debug":
		l = zerolog.DebugLevel
	default:
		l = zerolog.InfoLevel
	}
	zl = zl.Level(l)

	return zerologr.New(&zl)
}
