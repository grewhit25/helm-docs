#!/bin/bash
# (c) Artur.Klauser@computer.org
#
# This script installs support for building multi-architecture docker images
# with docker buildx on CI/CD pipelines like Github Actions or Travis. It is
# assumed that you start of with a fresh VM every time you run this and have to
# install everything necessary to support 'docker buildx build' from scratch.
#
# Example usage in Travis stage:
#
# jobs:
#   include:
#     - stage: Deploy docker image
#       script:
#         - source ./multi-arch-docker-ci.sh
#         - set -ex; buildx_images_ci::main; set +x
#
#  Platforms: linux/amd64, linux/arm64, linux/riscv64, linux/ppc64le,
#  linux/s390x, linux/386, linux/arm/v7, linux/arm/v6
# More information about Linux environment constraints can be found at:
# https://nexus.eddiesinentropy.net/2020/01/12/Building-Multi-architecture-Docker-Images-With-Buildx/

function _version() {
  printf '%02d' $(echo "$1" | tr . ' ' | sed -e 's/ 0*/ /g') 2>/dev/null
}

function buildx_images_ci::install_docker_buildx() {
  # Check kernel version.
  local -r kernel_version="$(uname -r)"
  if [[ "$(_version "$kernel_version")" < "$(_version '4.8')" ]]; then
    echo "Kernel $kernel_version too old - need >= 4.8."
    exit 1
  fi

  ## Install up-to-date version of docker, with buildx support.
  local -r docker_apt_repo='https://download.docker.com/linux/ubuntu'
  curl -fsSL "${docker_apt_repo}/gpg" | sudo apt-key add -
  local -r os="$(lsb_release -cs)"
  sudo add-apt-repository "deb [arch=amd64] $docker_apt_repo $os stable"
  sudo apt-get update
  sudo apt-get -y -o Dpkg::Options::="--force-confnew" install docker-ce

  # Enable docker daemon experimental support (for 'docker pull --platform').
  local -r config='/etc/docker/daemon.json'
  if [[ -e "$config" ]]; then
    sudo sed -i -e 's/{/{ "experimental": true, /' "$config"
  else
    echo '{ "experimental": true }' | sudo tee "$config"
  fi
  sudo systemctl restart docker

  # Install QEMU multi-architecture support for docker buildx.
  docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

  # Enable docker CLI experimental support (for 'docker buildx').
  export DOCKER_CLI_EXPERIMENTAL=enabled
  # Instantiate docker buildx builder with multi-architecture support.
  docker buildx create --name mybuilder
  docker buildx use mybuilder
  # Start up buildx and verify that all is OK.
  docker buildx inspect --bootstrap
}

# Log in to Docker Hub for deployment.
# Env:
#   DOCKER_USERNAME ... user name of Docker Hub account
#   DOCKER_PASSWORD ... password of Docker Hub account
function buildx_images_ci::login_to_docker_hub() {
  echo "$DOCKER_PASSWORD" | docker login --username "$DOCKER_USERNAME" --password-stdin

}


# Run buildx build and push.
# Env:
#   DOCKER_PLATFORMS ... space separated list of Docker platforms to build.
# Args:
#   Optional additional arguments for 'docker buildx build'.
function buildx_images_ci::buildx() {
  docker buildx build \
    --platform "${DOCKER_PLATFORMS// /,}" \
    --load \
    --progress plain \
    -f Dockerfile.multi-arch \
    "$@" \
    .
}

# Build and push docker images for all tags.
# Env:
#   DOCKER_PLATFORMS ... space separated list of Docker platforms to build.
#   DOCKER_BASE ........ docker image base name to build
#   TAGS ............... space separated list of docker image tags to build.
function buildx_images_ci::build_and_push_image() {
  for tag in $TAGS; do
    buildx_images_ci::buildx -t "$DOCKER_BASE:$tag"
    docker push "$DOCKER_BASE:$tag"
  done
}

# build manifest for indevidual images
# MANIFEST_ARCH='amd64 arm64 arm'
# 
function buildx_images_ci::create_push_manifest(){

  echo "Create manifest and push image"

  local MANIFESTS=""
  for arch in ${BUILD_ARCH}; do MANIFESTS="${MANIFESTS} ${DOCKER_BASE}:${arch}"; done
  docker manifest create --amend ${DOCKER_BASE} ${MANIFESTS};

  for arch in ${BUILD_ARCH}; do
    if [ ${arch} == "arm" ]; then
      ARCH="arm --variant v7"
    elif [ ${arch} == "arm64" ]; then
      ARCH="arm64 --variant v8"
    else
      ARCH="${arch}"
    fi
  docker manifest annotate ${DOCKER_BASE} ${DOCKER_BASE}:${arch} \
    --os 'linux' --arch ${ARCH}
  done

  docker manifest push ${DOCKER_BASE}
}

# Test all pushed docker images.
# Env:
#   DOCKER_PLATFORMS ... space separated list of Docker platforms to test.
#   DOCKER_BASE ........ docker image base name to test
#   TAGS ............... space separated list of docker image tags to test.
function buildx_images_ci::test_all() {
  for platform in $DOCKER_PLATFORMS; do
    for tag in $TAGS; do
      image="${DOCKER_BASE}:${tag}"
      msg="Testing docker image $image on platform $platform"
      line="${msg//?/=}"
      printf '\n%s\n%s\n%s\n' "${line}" "${msg}" "${line}"
      docker pull -q --platform "$platform" "$image"

      echo -n "Image architecture: "
      docker run --rm --entrypoint /bin/sh "$image" -c 'uname -m'

      # Run your test on the built image.
      docker run --rm -v "$PWD:/mnt" -w /mnt "$image" echo "Running on $(uname -m)"
    done
  done
}

# Setup ci environment
function buildx_images_ci::setup_environment() {
  cp ${DOCKERFILE} Dockerfile.multi-arch
  buildx_images_ci::install_docker_buildx
  buildx_images_ci::login_to_docker_hub
}

# Build and push images
function buildx_images_ci::build_images() {
  # build image
  buildx_images_ci::build_and_push_image
  buildx_images_ci::create_push_manifest
  
}