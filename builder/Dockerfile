# Alpine-based CodeBuild environment image for cftcl-release.
#
# Used as the env.image for both CodeBuild projects in the cftcl-release stack
# (one push per arch via `make release_builder_images`). Contains exactly what
# the buildspec needs: docker CLI + buildx, AWS CLI, ECR credential helper,
# abuild + apk-tools (for `apk index` + `abuild-sign`), jq, and a basic
# coreutils set. build_apk.tcl itself is not present here — it runs inside
# the cftcl-apk-prep image the buildspec produces.
#
# The credsStore=ecr-login config tells docker to consult the ECR credential
# helper for every registry lookup. For ECR hostnames it returns a fresh
# token via the CodeBuild execution-role IMDS path; for non-ECR registries
# (e.g. anonymous Docker Hub pulls of base images) the helper returns an
# error, which docker treats as "no credentials → try anonymous".

FROM alpine:3.24.1

RUN apk add --no-cache \
		abuild \
		apk-tools \
		aws-cli \
		bash \
		coreutils \
		curl \
		docker-cli \
		docker-cli-buildx \
		docker-credential-ecr-login \
		git \
		gzip \
		jq \
		openssl \
		tar \
		wget \
		xz

RUN mkdir -p /root/.docker \
 && printf '{"credsStore":"ecr-login"}\n' > /root/.docker/config.json

ENTRYPOINT ["/bin/bash"]
