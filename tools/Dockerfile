# syntax=docker/dockerfile:1
# burrowrs-tools: probes, smoke tests and offline QR codes.
# Two targets: "runtime" (default, used by `burrowrs`) and "test" (pytest + ruff).

ARG PYTHON_IMAGE=python:3.12-alpine@sha256:c5ba3deef00c7758561a0f03c26f44f10589263d40e732b8748e0d1f38f6dd89

FROM ${PYTHON_IMAGE} AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore
WORKDIR /app
COPY requirements.txt ./
# Hash-locked, wheels only: no compiler, no surprise sdists.
RUN pip install --require-hashes --only-binary=:all: --no-deps -r requirements.txt
COPY burrowrs_tools ./burrowrs_tools
# Byte-compile now: the runtime user can't write __pycache__ (and the root
# filesystem is read-only), so otherwise every probe recompiles from source.
RUN python -m compileall -q burrowrs_tools
USER 65534:65534
ENTRYPOINT ["python", "-m", "burrowrs_tools"]
CMD ["--help"]

FROM runtime AS test
USER root
COPY requirements-dev.txt ./
RUN pip install --require-hashes --only-binary=:all: --no-deps -r requirements-dev.txt
COPY pyproject.toml ./
COPY tests ./tests
USER 65534:65534
ENV PYTEST_ADDOPTS="-p no:cacheprovider"
ENTRYPOINT ["python", "-m", "pytest"]
CMD []

FROM runtime
