# syntax=docker/dockerfile:1
# Dockerfile -- combines pixel-agents (standalone webview server) and
# node-red-agents (Agentic Development Team demo flow) in one box, sharing
# ~/.pixel-agents via one $HOME so the ADT flow's built-in
# "cat ~/.pixel-agents/server.json" discovery just works. See README.md for
# what this is and AGENTS.md for build/run details and what to consider.
#
# Deliberately portable: every source tree is fetched via `git clone`
# inside the build, not via local build context -- so this single file can
# be copied anywhere and built with a throwaway context, e.g.:
#
#   mkdir /tmp/ctx && cd /tmp/ctx
#   docker build -f /path/to/Dockerfile -t pixel-agents-adt .
#
# Override --build-arg PIXEL_AGENTS_REPO/_REF and NODE_RED_AGENTS_REPO/_REF
# to point at forks/branches other than the defaults below.
#
# Scope decisions (see AGENTS.md for the full rationale):
#   - `adt-run-agent` keeps its real `runtime: "srt"` (Anthropic's
#     sandbox-runtime, @anthropic-ai/sandbox-runtime, installed globally
#     below) -- srt sandboxes via bubblewrap/user-namespaces, a second,
#     nested sandbox layer inside an already-containerized process, so
#     `docker run` needs the capability/security-opt flags documented in
#     AGENTS.md for `bwrap` to create its own namespaces.
#   - NEVER mount host credentials (e.g. ~/.local/share/opencode/auth.json)
#     into this image/container -- the default model, `opencode/big-pickle`,
#     is a free OpenCode Zen model that needs no auth at all, so there is
#     nothing to inject for opencode. Only `GH_TOKEN` (a plain env var, not
#     a file) is needed, since gh's keyring-backed auth (common on Linux
#     desktops) does not survive a headless container.
#   - Both processes die together: the entrypoint backgrounds both and
#     `wait -n`s; if either exits, the other is killed and the container
#     exits non-zero.

ARG PIXEL_AGENTS_REPO=https://github.com/tbrandenburg/pixel-agents.git
ARG PIXEL_AGENTS_REF=main
ARG NODE_RED_AGENTS_REPO=https://github.com/tbrandenburg/node-red-agents.git
ARG NODE_RED_AGENTS_REF=main

# ---------------------------------------------------------------------------
# Stage: pixel-agents build (standalone CLI -> dist/cli.js + webview + assets)
# ---------------------------------------------------------------------------
FROM node:22-bookworm AS pixel-builder
ARG PIXEL_AGENTS_REPO
ARG PIXEL_AGENTS_REF
# Optional corporate/TLS-intercepting-proxy CA bundle (e.g. Netskope), injected
# only via `docker build --secret id=cacert,src=<path>`. No-op if not supplied
# -- this keeps the image buildable from a throwaway context on unrestricted
# networks, per the portability goal above.
RUN --mount=type=secret,id=cacert \
    if [ -s /run/secrets/cacert ]; then \
      cp /run/secrets/cacert /usr/local/share/ca-certificates/corporate-ca.crt \
      && update-ca-certificates; \
    fi
# npm/Node use their own bundled CA list, not the OS trust store, so point it
# at the (possibly corporate-CA-merged) system bundle too -- harmless no-op
# when no secret was supplied, since it's still the standard public CA set.
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
WORKDIR /src
RUN git clone --depth 1 --branch "${PIXEL_AGENTS_REF}" "${PIXEL_AGENTS_REPO}" pixel-agents
WORKDIR /src/pixel-agents
RUN npm install
RUN npm run build

# ---------------------------------------------------------------------------
# Stage: node-red-agents build (root workspace + demo/ userDir, no compile step)
# ---------------------------------------------------------------------------
FROM node:22-bookworm AS nodered-builder
ARG NODE_RED_AGENTS_REPO
ARG NODE_RED_AGENTS_REF
RUN --mount=type=secret,id=cacert \
    if [ -s /run/secrets/cacert ]; then \
      cp /run/secrets/cacert /usr/local/share/ca-certificates/corporate-ca.crt \
      && update-ca-certificates; \
    fi
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
WORKDIR /src
RUN git clone --depth 1 --branch "${NODE_RED_AGENTS_REF}" "${NODE_RED_AGENTS_REPO}" node-red-agents
WORKDIR /src/node-red-agents
RUN npm install
WORKDIR /src/node-red-agents/demo
RUN npm install
# PoC scope decision: srt's own vendored bwrap needs `enableWeakerNestedSandbox`
# to run inside an already-containerized environment (its own source comment:
# "not available when running in unprivileged docker containers" -- see
# linux-sandbox-utils.js). advancedJson *replaces* the whole settings object
# (not a merge -- see packages/node-red-agents/shared/srt-settings.js), so this
# reconstructs each node's existing network/filesystem settings verbatim and
# adds the one new top-level key.
#
# Patches EVERY node with runtime === "srt" in flows.json, not just
# `adt-run-agent` -- the demo flow ships several other srt-runtime agent
# nodes (e.g. the Playground tab's "Sandboxed Agent" and "Parallel Agents",
# both hardcoded to model "opencode/big-pickle"), and every one of them hits
# the identical "apply-seccomp: write /proc/self/uid_map: Operation not
# permitted" failure without this flag -- there is nothing agent-node- or
# flow-specific about the requirement, it's purely a property of running srt
# inside Docker at all. "models.opencode.ai" is added to each node's allowed
# domains unconditionally too: it's the real API host behind the free
# `opencode/big-pickle` model (srt matches domains exact-host, not by
# wildcard, so the already-allowed "opencode.ai" does not cover its "models."
# subdomain), and adding it is harmless for nodes that don't use that model.
RUN node -e '\
const fs = require("fs"); \
const path = "flows.json"; \
const flows = JSON.parse(fs.readFileSync(path, "utf-8")); \
const srtNodes = flows.filter((n) => n.runtime === "srt"); \
if (srtNodes.length === 0) throw new Error("no runtime=srt nodes found in flows.json"); \
for (const node of srtNodes) { \
  const allowedDomains = Array.from(new Set([...(node.srtAllowedDomains || []), "models.opencode.ai"])); \
  node.srtAdvancedJson = JSON.stringify({ \
    network: { allowedDomains, deniedDomains: [], strictAllowlist: node.srtStrictAllowlist !== false }, \
    filesystem: { allowWrite: [...(node.srtAllowedWriteDirs || []), "~/.cache", "~/.config", "~/.local/state", "~/.opencode"], denyRead: [], denyWrite: [] }, \
    enableWeakerNestedSandbox: true, \
  }); \
  console.log(`patched ${node.name || node.id} (${node.id}).srtAdvancedJson:`, node.srtAdvancedJson); \
} \
fs.writeFileSync(path, JSON.stringify(flows, null, 4)); \
console.log(`patched ${srtNodes.length} srt-runtime node(s) total`); \
'

# ---------------------------------------------------------------------------
# Stage: runtime -- both apps, one $HOME, one entrypoint
# ---------------------------------------------------------------------------
FROM node:22-bookworm-slim AS runtime

# gh CLI (official apt repo) + git (worktrees) + curl/ca-certs (opencode installer)
# + bubblewrap (bwrap -- the sandbox srt/@anthropic-ai/sandbox-runtime wraps around)
# + ripgrep/socat -- srt's own runtime dependencies (verified: it fails fast with
# "Sandbox dependencies not available: ripgrep (rg) not found, socat not installed"
# without them)
# apt itself uses plain HTTP mirrors so ca-certificates isn't needed yet here;
# it's installed first so the optional corporate CA (below) can be merged into
# the trust store before any HTTPS curl calls run.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates git gnupg bubblewrap ripgrep socat
# Optional corporate/TLS-intercepting-proxy CA bundle (e.g. Netskope), injected
# only via `docker build --secret id=cacert,src=<path>`. No-op if not supplied
# -- this keeps the image buildable from a throwaway context on unrestricted
# networks, per the portability goal at the top of this file.
RUN --mount=type=secret,id=cacert \
    if [ -s /run/secrets/cacert ]; then \
      cp /run/secrets/cacert /usr/local/share/ca-certificates/corporate-ca.crt \
      && update-ca-certificates; \
    fi
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# opencode CLI (official installer, installs to ~/.opencode/bin)
RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/root/.opencode/bin:${PATH}"

# srt (Anthropic sandbox-runtime) -- npm package, binary at dist/cli.js
RUN npm install -g @anthropic-ai/sandbox-runtime

WORKDIR /app
COPY --from=pixel-builder /src/pixel-agents /app/pixel-agents
COPY --from=nodered-builder /src/node-red-agents /app/node-red-agents

RUN cat <<'ENTRYPOINT_EOF' > /app/entrypoint.sh
#!/usr/bin/env bash
# Starts pixel-agents (standalone) + node-red-agents (ADT demo instance) in
# one container, sharing $HOME so the ADT flow's `cat
# ~/.pixel-agents/server.json` discovery works with zero configuration.
# "They die together": if either process exits, the other is killed and
# this script exits non-zero.
set -uo pipefail

PIXEL_PORT="${PIXEL_PORT:-3100}"
DEMO_PORT="${DEMO_PORT:-1881}"
HOME_MIRROR="${HOME_MIRROR:-/home-mirror}"

# Import optional, user-provided OpenCode config/auth into the container HOME.
# The mirror is mounted read-only by `make run`; only its contents are copied.
# `cp -a` preserves the mirror's on-disk ownership verbatim (typically the
# host user's uid, e.g. 1000) -- srt's nested user namespace (apply-seccomp's
# own inner unshare-user, see AGENTS.md "The srt patch") only grants root
# override power over files owned by a uid mapped into that namespace; a
# foreign host uid falls back to plain permission bits (usually 0755,
# owner-write-only) and any sandboxed agent EACCESs trying to write there.
# Re-own everything as root right after the copy so it matches the uid srt's
# sandbox actually runs as (verified: `id` inside `srt` reports uid=0).
if [ -d "$HOME_MIRROR" ]; then
  cp -a "$HOME_MIRROR"/. "$HOME"/
  chown -R root:root "$HOME"
fi

pixel_home="${HOME}/.pixel-agents"

mkdir -p "$pixel_home"
config_json="${pixel_home}/config.json"

# srt's allow-write list only allow-lists the leaf dirs, not their non-existent
# parents in a fresh container -- opencode's own `mkdir -p` recursion into
# ~/.local/share/opencode, ~/.cache, ~/.config, ~/.local/state/opencode, and
# ~/.opencode all fail EROFS inside the sandbox otherwise. Pre-create them
# here (outside the sandbox) once.
mkdir -p "${HOME}/.local/share/opencode" "${HOME}/.cache" "${HOME}/.config" "${HOME}/.local/state/opencode" "${HOME}/.opencode"
node -e '
  const fs = require("fs");
  const path = process.argv[1];
  let config = {};
  try { config = JSON.parse(fs.readFileSync(path, "utf-8")); } catch {}
  config.standalone = { ...(config.standalone ?? {}), watchAllSessions: true, alwaysShowLabels: true };
  fs.writeFileSync(path, JSON.stringify(config, null, 2));
' "$config_json"
echo "[entrypoint] pixel-agents config: watchAllSessions+alwaysShowLabels -> ${config_json}"

echo "[entrypoint] starting pixel-agents on :${PIXEL_PORT}..."
node /app/pixel-agents/dist/cli.js --port "$PIXEL_PORT" --host 0.0.0.0 &
pixel_pid=$!

echo "[entrypoint] waiting for ${pixel_home}/server.json..."
server_json="${pixel_home}/server.json"
for _ in $(seq 1 50); do
  [ -f "$server_json" ] && break
  sleep 0.1
done
if [ -f "$server_json" ]; then
  echo "[entrypoint] pixel-agents ready: $(cat "$server_json")"
else
  echo "[entrypoint] WARNING: ${server_json} did not appear within 5s" >&2
fi

echo "[entrypoint] starting node-red-agents demo (ADT) on :${DEMO_PORT}..."
# cwd must be the node-red-agents repo root (not demo/), because demo/flows.json's
# `file in` nodes load prompts/read-only/*.md via paths relative to the repo
# root -- matching how `make demo` runs it (Makefile invokes node-red from the
# root with `--userDir ./demo`).
( cd /app/node-red-agents && DEMO_PORT="$DEMO_PORT" node node_modules/.bin/node-red --userDir ./demo ) &
nodered_pid=$!

cleanup() {
  echo "[entrypoint] shutting down (pixel_pid=$pixel_pid nodered_pid=$nodered_pid)..."
  kill "$pixel_pid" "$nodered_pid" 2>/dev/null || true
  wait "$pixel_pid" "$nodered_pid" 2>/dev/null
}
trap cleanup EXIT INT TERM

# Die together: whichever exits first triggers cleanup of the other, and we
# propagate a non-zero exit so `docker ps`/health checks see the failure.
wait -n "$pixel_pid" "$nodered_pid"
exit_code=$?
echo "[entrypoint] one process exited (code $exit_code) -- stopping the other."
exit "$exit_code"
ENTRYPOINT_EOF
RUN chmod +x /app/entrypoint.sh

EXPOSE 3100 1881

ENTRYPOINT ["/app/entrypoint.sh"]
