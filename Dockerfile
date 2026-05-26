# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile for ignitetech-group/action-ecs-deploy.
#
# Base: CPython 3.13 on Debian Trixie (Debian 13). Ships glibc 2.41 +
# OpenSSL 3.5, both newer than alpine:3.19's stack, and matches the libc/
# SSL stack used by gfi-mcp + ignitetech-group/ecs-deploy so security
# advisories track in lockstep.
#
# Build: stage 1 (builder) installs the ecs CLI + its full transitive dep
# tree from the SHA-hashed lockfile (requirements.txt). Stage 2 (runtime)
# is a minimal slim-trixie image that copies the venv across. The pip
# cache, uv binary, git, and all build deps live only in stage 1.
#
# Why a from-source build at all
# ------------------------------
# The upstream donaldpiret/ecs-deploy uses `FROM fabfuel/ecs-deploy:1.11.3`
# (Docker Hub). That places trust in:
#   - whoever controls the fabfuel Docker Hub account
#   - whoever controls Docker Hub's tag-mutation policy
#   - the maintainability of a 2022-vintage tag (1.11.3) that is now several
#     minor versions behind upstream's Python source
# We replace that chain with a SHA-pinned `pip install` from our fork of
# fabfuel/ecs-deploy, where every transitive package version is hashed.

# ---------------------------------------------------------------------------
# Builder stage
# ---------------------------------------------------------------------------
FROM python:3.13-slim-trixie AS builder

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

# git + ca-certificates: needed to fetch the ecs-deploy source from
# git+https://github.com/ignitetech-group/ecs-deploy@<SHA>. apt build deps
# are kept only in this stage.
# DL3008 (pin apt versions) suppressed: Debian's apt index rotates as
# point releases ship; pinning exact `pkg=version-rN` strings here would
# cause the build to fail whenever Debian retires an old revision.
# Reproducibility is anchored at the base image tag (python:3.13-slim-
# trixie), which is the same trade-off used by ignitetech-group/gfi-mcp.
# hadolint ignore=DL3008
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      git && \
    rm -rf /var/lib/apt/lists/*

# Install uv (fast resolver/installer). Pinned by digest to the 0.11.15
# release. Using ghcr.io/astral-sh/uv@sha256:... rather than :tag because
# the tag is mutable. Earlier 0.8.x versions are affected by three
# published advisories in archive extraction:
#   GHSA-7j9j-68r2-f35q  tar sdist path traversal       (patched 0.8.22)
#   CVE-2025-13327       ZIP install differential       (patched 0.9.6)
#   GHSA-w476-p2h3-79g9  PAX tar size differential      (patched 0.9.5)
# 0.11.15 is the latest stable that has been published >=7 days
# (matches the dependency-cooldown applied to requirements.txt).
COPY --from=ghcr.io/astral-sh/uv@sha256:e590846f4776907b254ac0f44b5b380347af5d90d668138ca7938d1b0c2f98d3 /uv /uvx /usr/local/bin/

WORKDIR /build

# Build the venv from the hashed lockfile. uv pip sync verifies every
# wheel hash against requirements.txt; a mismatch aborts the build.
RUN python -m venv /opt/venv
COPY requirements.txt ./
RUN uv pip sync --python /opt/venv/bin/python requirements.txt

# ---------------------------------------------------------------------------
# Runtime stage
# ---------------------------------------------------------------------------
FROM python:3.13-slim-trixie

LABEL org.opencontainers.image.source="https://github.com/ignitetech-group/action-ecs-deploy"
LABEL org.opencontainers.image.description="ignitetech-group fork of donaldpiret/ecs-deploy, building fabfuel ecs-deploy from a pinned source SHA"
LABEL org.opencontainers.image.licenses="MIT"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PATH="/opt/venv/bin:${PATH}"

# Runtime dependencies only:
#   * ca-certificates: HTTPS to AWS endpoints (boto3 verifies certs)
#   * jq: callers occasionally pipe JSON through jq
# entrypoint.sh uses bash + xargs + readarray; bash 5.2 and xargs are in
# the python:3.13-slim-trixie base image (verified 2026-05-25), so we do
# NOT need to install them.
# hadolint ignore=DL3008
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      jq && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv

# Run as a non-root user. uid 1001 is the project standard and matches
# the gfi-mcp / ignitetech-group/ecs-deploy convention used elsewhere in
# the org. /home/app is created by useradd --create-home and is writable
# only by app, which is what we want for any side-effects entrypoint.sh
# might produce (none today, but a defensive default).
RUN useradd --system --uid 1001 --create-home --shell /usr/sbin/nologin app
WORKDIR /home/app

COPY --chown=app:app entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER app

ENTRYPOINT ["/entrypoint.sh"]
