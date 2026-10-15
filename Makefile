# No bare `export`: it handed every variable - GITHUB_GH_TOKEN included - to every recipe, i.e. to
# cmake, the compilers, the test binaries and the pre-commit hooks. The release credential is
# exported ONLY to the targets that use it (CREDENTIAL_TARGETS below), and
# the global `unexport` keeps it out of every other recipe even when it arrives from the
# environment (run_release_with_devops sets it there for `$(MAKE) release`).
unexport GITHUB_GH_TOKEN GH_TOKEN GITHUB_TOKEN

# =====================================================================================
# ondewo-vtsi-client-cpp - Makefile
#
# The ONDEWO VTSI (Virtual Telephony Server Interface) gRPC client library for C++.
#
# There is no hand-written client code in this repository: everything under api/ is
# generated from the .proto files of the ondewo-vtsi-api submodule by the
# ondewo-cpp-proto-compiler docker image (the ondewo-proto-compiler submodule), which
# also packages the result as a consumable CMake package.
#
# Quick start:
#   make help                    # list every documented target
#   make makefile_chapters       # list the section headers below
#   make build                   # submodules -> compiler image -> stubs -> library
#   make test                    # verify the generated code and consume the CMake package
#   make publish_dry_run         # build the release archive and consume it - no credentials
#
# Versioning: ONDEWO_VTSI_VERSION (below) is the single source of truth and MUST
# match the ONDEWO VTSI API in major and minor version.
#
# Overriding variables: pass on the command line, e.g. `make build LIBRARY_NAME=my_client`,
# or export in the environment. Credentials (GITHUB_GH_TOKEN) are only ever read at runtime
# and must never be committed.
# =====================================================================================

# ---------------- BEFORE RELEASE ----------------
# 1 - Update Version Number
# 2 - Update RELEASE.md
# 3 - make build
# -------------- Release Process Steps --------------
# `make ondewo_release` (or `make release` with GITHUB_GH_TOKEN exported):
# 1 - spc, then the credential is read from devops-accounts and the clone is deleted at once
# 2 - release_preflight: host tools, release notes, token valid with push rights, version unreleased
# 3 - generate the stubs, build the library, run the FULL test suite incl. the packaging dry-run
# 4 - commit, push, release branch, release tag
# 5 - GitHub release with the RELEASE.md notes (gh in the pinned GH_IMAGE)
# 6 - .github/workflows/release.yml - the ONLY uploader - attaches the archive from the tag push;
#     release_verify waits for it, downloads it and checks it with `sha256sum -c`

########################################################
# 		Variables
########################################################

# MUST BE THE SAME AS THE API IN MAJOR AND MINOR VERSION NUMBER
# example: API 2.9.0 --> Client 2.9.X
# CMake's project(VERSION ...) and write_basic_package_version_file() only accept a dotted
# numeric MAJOR.MINOR.PATCH here - a pre-release suffix such as 1.2.0-rc1 aborts the configure
# step, so the compiler image rejects it up front.
ONDEWO_VTSI_VERSION=9.1.0

# Submodule pins. Both are checked out by `make checkout_defined_submodule_versions`, which is
# part of `make build`, so a build is always reproducible from these two lines alone.
ONDEWO_VTSI_API_GIT_BRANCH=tags/9.1.0
ONDEWO_PROTO_COMPILER_GIT_BRANCH=tags/5.15.7

# You need to setup an access token at https://github.com/settings/tokens - permissions are important
GITHUB_GH_TOKEN?=ENTER_YOUR_TOKEN_HERE

ONDEWO_API_DIR=ondewo-vtsi-api
ONDEWO_PROTO_COMPILER_DIR=ondewo-proto-compiler

# The image tag is the ONLY contract with the proto compiler - `make build_compiler` rebuilds it
# from the submodule. It is tagged with the compiler version pinned above, never with an implicit
# :latest, so a generation can only run against the compiler the pin names (the driver in
# ondewo-vtsi-api rewrites ONDEWO_PROTO_COMPILER_GIT_BRANCH=tags/<version> before a release).
PROTO_COMPILER_VERSION=$(patsubst tags/%,%,$(ONDEWO_PROTO_COMPILER_GIT_BRANCH))
PROTO_COMPILER_IMAGE=ondewo-cpp-proto-compiler:$(PROTO_COMPILER_VERSION)

# Entrypoint argument 1: the proto root, relative to the mounted /input-volume (the repo root).
# Entrypoint argument 2: the sub-directory of that root whose protos are the compilation entry
# points; their transitive imports (google/**, minus the well-known types already inside
# libprotobuf) are pulled in automatically, so google/ must NOT be listed here.
# Entrypoint argument 3: the CMake target / package / archive name. C++ has no package manifest
# the image could read a name from, so it arrives positionally. Letters, digits, '_' and '-' only.
ONDEWO_PROTOS_SUBDIR=ondewo
LIBRARY_NAME=ondewo_vtsi_client

# Host-side CMake build of the generated stubs. BUILD_DIR is throwaway; the install tree lands at
# the repo root so include/, lib/lib$(LIBRARY_NAME).a and lib/cmake/$(LIBRARY_NAME)/ sit exactly
# where the compiler image writes them (all three are gitignored build output).
BUILD_DIR=build
INSTALL_PREFIX=$(CURDIR)
# getconf, not nproc: nproc is a GNU coreutils extension and does not exist on macOS. Lower this
# on a small machine - each cc1plus on a large generated .pb.cc needs a few hundred MB of RAM.
BUILD_JOBS?=$(shell getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
SMOKE_TEST_DIR=.smoke-test

# The release host need not carry the C++ toolchain. Without cmake on PATH, `make release` runs
# build_library, test and publish_dry_run inside TOOLCHAIN_IMAGE (toolchain.Dockerfile, the same
# ubuntu-24.04 packages CI installs) as the calling user, with the repository mounted at the same
# path. Code generation stays on the host (it is docker already) and so does the upload: the
# release credential never enters the container. A host with cmake, and CI, are unchanged.
TOOLCHAIN_IMAGE=ondewo-vtsi-client-cpp-toolchain:ubuntu-24.04
USE_DOCKER_TOOLCHAIN?=$(if $(shell command -v cmake 2>/dev/null),false,true)
# $(call toolchain,<target>) -> in_toolchain_<target> when the docker toolchain is used, else <target>
toolchain=$(if $(filter true,$(USE_DOCKER_TOOLCHAIN)),in_toolchain_$(1),$(1))

# The release archive - this client's ONLY distribution channel for a prebuilt consumer. C++ has
# no package registry, so `make build_package` stages the CMake install tree into a versioned
# directory and tars it, and the release workflow attaches it to the GitHub release;
# `find_package(<library> CONFIG REQUIRED)` against the extracted archive is what the generated
# *-config.cmake files exist for.
# The archive is a BINARY artifact (static archive + headers + CMake package files), so the name
# carries the platform it was built on and PACKAGE-INFO.txt inside records the exact protobuf/gRPC
# it was compiled against - C++ gencode and runtime have no cross-version guarantee.
PACKAGE_DIR=dist
PACKAGE_PLATFORM?=$(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
PACKAGE_NAME=$(LIBRARY_NAME)-$(ONDEWO_VTSI_VERSION)-$(PACKAGE_PLATFORM)
PACKAGE_STAGE_DIR=$(PACKAGE_DIR)/$(PACKAGE_NAME)
PACKAGE_ARCHIVE=$(PACKAGE_DIR)/$(PACKAGE_NAME).tar.gz
# Throwaway tree for verify_package: the archive is extracted here and consumed from
# tests/package-consume, exactly the way a downstream project consumes it.
PACKAGE_TEST_DIR=.package-test
PACKAGE_CONSUME_DIR=tests/package-consume

# GoogleTest/CTest suite over the committed stubs. tests/ is a STANDALONE CMake project that
# consumes the installed package (see tests/CMakeLists.txt for why it is not a subdirectory of
# the generated root CMakeLists.txt), so it needs its own build tree.
TEST_DIR=tests
TEST_BUILD_DIR=build-tests
# Line-coverage floor for the HAND-WRITTEN sources under tests/ and client/ (the header-only
# channel helper). The generated stubs are excluded by construction: the client archive is
# compiled without --coverage, so no .gcno for a *.pb.cc exists at all, and the gcovr filter
# below keeps the metric inside tests/ and client/.
COVERAGE_MIN?=100

# Terminate on the ***** separator that delimits release entries, NOT on /\*\*/ - that matches the
# first markdown **bold** span inside the entry and silently truncates the notes there, with no
# error from `gh release create`. The '+' of "C++" is escaped because an unescaped one is a perl
# regex quantifier ("Nested quantifiers in regex") - keep the escaping if you rename the heading.
# The heading is ANCHORED (`^#+ ... \Q<version>\E$$`): unanchored, the notes of 9.1.1 would also
# be sliced out of a "9.1.10" heading, and \Q..\E makes the dots of the version literal.
CURRENT_RELEASE_NOTES=`cat RELEASE.md \
	| perl -ne 'print if /^\#+ Release ONDEWO VTSI C\+\+ Client \Q${ONDEWO_VTSI_VERSION}\E$$/../^\*{5}/'`

GH_REPO_PATH=ondewo/ondewo-vtsi-client-cpp
GH_REPO="https://github.com/$(GH_REPO_PATH)"
DEVOPS_ACCOUNT_GIT=ondewo-devops-accounts
# How run_release_with_devops obtains the credentials when DEVOPS_ACCOUNT_DIR (environment) does not
# name an existing clone: cloned into a fresh `mktemp -d` OUTSIDE the repository - never into a
# directory that is mounted into a container - and deleted again before `$(MAKE) release` starts.
# Overridable only so tests/test_release_order.sh can feed a fixture instead of the real repo.
DEVOPS_ACCOUNT_CLONE=git clone -q --depth 1 git@bitbucket.org:ondewo/$(DEVOPS_ACCOUNT_GIT).git

# The GitHub CLI runs in a pinned image (gh.Dockerfile), so the release host needs no gh at all.
# The token reaches it per call - `GH_TOKEN="$$GITHUB_GH_TOKEN" $(GH_RUN) gh ...` puts it into the
# environment of the docker client, and `-e GH_TOKEN` copies it from there into the container -
# never on an argv, never in a file, and there is no `gh auth login` on the host.
GH_VERSION=$(shell sed -n 's/^ARG GH_VERSION=//p' gh.Dockerfile)
GH_IMAGE=ondewo-vtsi-client-cpp-gh:$(GH_VERSION)
GH_RUN=docker run --rm -i --user "`id -u`:`id -g`" -e HOME=/tmp -e GH_TOKEN $(GH_IMAGE)

# The targets the release credential is exported to - ONE line, so that every target is still
# defined by exactly one `<target>:` line (prerequisites of these inherit the export). Everything
# else - cmake, the compilers, the tests, pre-commit - runs without it (the global `unexport` above).
# upload_package is the release workflow's step and gets the runner's GH_TOKEN the same way.
CREDENTIAL_TARGETS=TEST release release_preflight check_release_credentials check_gh_token_valid \
	check_version_unreleased build_gh_release push_to_gh release_verify
$(CREDENTIAL_TARGETS): export GITHUB_GH_TOKEN := $(GITHUB_GH_TOKEN)
CI_UPLOAD_TARGETS=upload_package
$(CI_UPLOAD_TARGETS): export GH_TOKEN := $(GH_TOKEN)

# The release driver (ondewo-vtsi-api) also runs `make release_preflight` and `make release_verify`
# STANDALONE, with only an absolute DEVOPS_ACCOUNT_DIR in the environment. Every recipe line that
# uses the token therefore starts with this: when GITHUB_GH_TOKEN is not already set, it is read
# from $$DEVOPS_ACCOUNT_DIR/account_github.env (anchored ^NAME=) into THAT line's shell only -
# never onto an argv, never into a log, never into a file. The name carries no TOKEN on purpose:
# tests/test_release_makefile_hygiene.sh flags a make-expanded $(...TOKEN...) in a recipe.
LOAD_RELEASE_CREDENTIALS=if { [ -z "$$GITHUB_GH_TOKEN" ] || [ "$$GITHUB_GH_TOKEN" = "ENTER_YOUR_TOKEN_HERE" ]; } \
	&& [ -n "$${DEVOPS_ACCOUNT_DIR:-}" ] && [ -f "$${DEVOPS_ACCOUNT_DIR}/account_github.env" ]; then \
	set -a; eval "`grep -h -E '^GITHUB_GH_TOKEN=' "$${DEVOPS_ACCOUNT_DIR}/account_github.env"`"; set +a; fi

# Non-empty under `make -n`. make executes a recipe line holding $(MAKE) even then, so
# run_release_with_devops checks this and clones nothing in a dry run.
MAKE_DRY_RUN=$(findstring n,$(firstword -$(MAKEFLAGS)))

# `make` with no target prints the help listing.
.DEFAULT_GOAL := help

# Define colors globally (reused for [INFO]/[SUCCESS]/[WARN]/[ERROR] log lines in recipes)
BLUE   := \033[1;34m
GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
NC     := \033[0m

########################################################
#       ONDEWO Standard Make Targets
########################################################

setup_developer_environment_locally: update_submodules install_precommit_hooks ## Ready a fresh checkout: initialize the submodules and install the pre-commit hooks

install_precommit_hooks: ## Installs pre-commit hooks and sets them up for the ondewo-vtsi-client-cpp repo
	pip install pre-commit
	pre-commit install
	pre-commit install --hook-type commit-msg

precommit_hooks_run_all_files: ## Runs all pre-commit hooks on all files and not just the changed ones
	pre-commit run --all-files

help: ## Print usage info about help targets
	# (first comment after target starting with double hashes ##)
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-40s\033[0m %s\n", $$1, $$2}'

makefile_chapters: ## Shows all sections of Makefile
	@echo `cat Makefile| grep "########################################################" -A 1 | grep -v "########################################################"`

TEST: ## Diagnostics - report whether release credentials are set and print the current release notes
# The placeholder counts as unset - `$(if $(GITHUB_GH_TOKEN),...)` alone reports "yes" for the
# default ENTER_YOUR_TOKEN_HERE and hides the one thing this line exists to tell you.
	@$(LOAD_RELEASE_CREDENTIALS); \
	if [ -z "$${GITHUB_GH_TOKEN}" ] || [ "$${GITHUB_GH_TOKEN}" = "ENTER_YOUR_TOKEN_HERE" ]; then \
		echo "GITHUB_GH_TOKEN is set: no"; \
	else \
		echo "GITHUB_GH_TOKEN is set: yes"; \
	fi
	@echo "Library name:           $(LIBRARY_NAME)"
	@echo "Client version:         $(ONDEWO_VTSI_VERSION)"
	@echo "Release archive:        $(PACKAGE_ARCHIVE)"
	@printf '\n%s\n' "${CURRENT_RELEASE_NOTES}"

########################################################
#       Repo Specific Make Targets
########################################################
#		Build

build: checkout_defined_submodule_versions build_compiler generate_ondewo_protos build_library ## Build source code: submodules -> compiler image -> generated stubs -> CMake library

# The same `docker build --no-cache` as the submodule's cpp/build.sh, but tagged with the pinned
# compiler version instead of build.sh's hard-coded :latest. The build context is the submodule's
# cpp/ directory only.
build_compiler: ## Build the ondewo-cpp-proto-compiler:<version> docker image from the submodule
	@echo "$(BLUE)[INFO]$(NC) Building $(PROTO_COMPILER_IMAGE) from $(ONDEWO_PROTO_COMPILER_DIR)/cpp ..."
	docker build --no-cache -t $(PROTO_COMPILER_IMAGE) $(ONDEWO_PROTO_COMPILER_DIR)/cpp
	@echo "$(GREEN)[SUCCESS]$(NC) $(PROTO_COMPILER_IMAGE) built"

# Derived from ondewo-proto-compiler/cpp/example/run-compile.sh: same image tag, same three
# positional arguments. There is deliberately NO `-it` - it breaks every non-interactive caller
# with "cannot attach stdin to a TTY-enabled container because stdin is not a terminal" - and no
# `--user` either, because the image's scripts write into the root-owned /image-data tree
# (fix_file_ownership below hands the results back afterwards).
#
# The INPUT volume is assembled from exactly what the compiler reads, each mounted read-only: the
# ondewo-vtsi-api proto tree, the two committed build files and the hand-written client/ helper the
# committed CMakeLists.txt installs. It used to be the whole repository root, which (a) showed the
# root container everything in the working tree - a devops-accounts clone included - and (b) fed
# the COMMITTED public-api.h back in, which the image then used verbatim instead of regenerating
# it, so a .proto added upstream would never have reached the umbrella header.
# The OUTPUT volume is the repository root, where the generated library belongs. The image only
# ever deletes what it owns there (api/, include/$(LIBRARY_NAME)/, lib/lib$(LIBRARY_NAME).a,
# lib/cmake/$(LIBRARY_NAME)/), overwrites the wholly generated public-api.h, and never overwrites an
# existing CMakeLists.txt / ondewo-client-config.cmake.in (it writes api/*.generated instead).
generate_ondewo_protos: ## Generate the C++ gRPC client stubs and the CMake library from the .proto files
	@echo "$(BLUE)[INFO]$(NC) Generating C++ stubs from $(ONDEWO_API_DIR)/$(ONDEWO_PROTOS_SUBDIR) into api/ ..."
	docker run --rm \
		-v "$(CURDIR)/$(ONDEWO_API_DIR):/input-volume/$(ONDEWO_API_DIR):ro" \
		-v "$(CURDIR)/CMakeLists.txt:/input-volume/CMakeLists.txt:ro" \
		-v "$(CURDIR)/ondewo-client-config.cmake.in:/input-volume/ondewo-client-config.cmake.in:ro" \
		-v "$(CURDIR)/client:/input-volume/client:ro" \
		-v "$(CURDIR):/output-volume" \
		$(PROTO_COMPILER_IMAGE) $(ONDEWO_API_DIR) $(ONDEWO_PROTOS_SUBDIR) $(LIBRARY_NAME)
	-make fix_file_ownership
	@echo "$(GREEN)[SUCCESS]$(NC) Stubs generated"

# `-` prefixed wherever it is called: a machine without sudo, or a Docker setup that already maps
# ownership to the calling user (Docker Desktop on macOS), must not fail the build here.
fix_file_ownership: ## Take back ownership of the files the (root) compiler container wrote into the repo
	@if [ "`id -u`" = "0" ]; then \
		echo "$(YELLOW)[NOOP]$(NC) running as root - nothing to restore"; \
	elif command -v sudo >/dev/null 2>&1; then \
		echo "$(BLUE)[INFO]$(NC) Restoring ownership of root-owned files (sudo may prompt) ..."; \
		find . -user 0 2>/dev/null | while IFS= read -r f; do \
			sudo chown -R "`id -u`:`id -g`" "$$f" && echo "  $$f"; \
		done; \
	else \
		echo "$(YELLOW)[NOOP]$(NC) sudo not available - skipping ownership restore"; \
	fi

# The host-native rebuild of the very same sources the image compiled. It is not redundant: the
# archive the image produces is linked against Debian's glibc/libstdc++ and will not necessarily
# link on this host, and this is the build a consumer of the repository actually performs.
build_library: ## Configure, compile and install the CMake library from the generated stubs
	@test -f CMakeLists.txt || { \
		echo "$(RED)[ERROR]$(NC) no CMakeLists.txt in the repository root - run 'make generate_ondewo_protos' first"; \
		exit 1; \
	}
	@echo "$(BLUE)[INFO]$(NC) Building $(LIBRARY_NAME) $(ONDEWO_VTSI_VERSION) with $(BUILD_JOBS) parallel jobs ..."
	cmake -S . -B $(BUILD_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$(INSTALL_PREFIX)" \
		-DONDEWO_LIBRARY_NAME=$(LIBRARY_NAME) \
		-DONDEWO_LIBRARY_VERSION=$(ONDEWO_VTSI_VERSION)
	cmake --build $(BUILD_DIR) --parallel $(BUILD_JOBS)
	cmake --install $(BUILD_DIR)
	@echo "$(GREEN)[SUCCESS]$(NC) lib/lib$(LIBRARY_NAME).a + lib/cmake/$(LIBRARY_NAME)/ installed into $(INSTALL_PREFIX)"

toolchain_image: ## Build the pinned ubuntu-24.04 CMake/protoc toolchain image (toolchain.Dockerfile)
	docker build -t $(TOOLCHAIN_IMAGE) - < toolchain.Dockerfile

# Only HOME is passed into the container: no host variable - GITHUB_GH_TOKEN least of all - may
# reach the toolchain's environment (the token is unexported here anyway, see the top of the file).
in_toolchain_%: toolchain_image ## Run `make <target>` inside the toolchain image, e.g. `make in_toolchain_test`
	docker run --rm -v "$(CURDIR):$(CURDIR)" -w "$(CURDIR)" --user "`id -u`:`id -g`" -e HOME=/tmp \
		$(TOOLCHAIN_IMAGE) make $* USE_DOCKER_TOOLCHAIN=false

clean: ## Remove the CMake build trees, the installed artifacts, the release archive and the scratch directories
	rm -rf $(BUILD_DIR) $(TEST_BUILD_DIR) $(SMOKE_TEST_DIR) $(PACKAGE_DIR) $(PACKAGE_TEST_DIR) include lib
	rm -f build_check.txt build_check_tmp.txt

clean_generated_stubs: ## Remove the generated stub sources (api/ and public-api.h) - they are regenerated by `make build`
	rm -rf api
	rm -f public-api.h

########################################################
#		Test

test: check_stubs check_build unit_test smoke_test publish_dry_run ## Full local gate: stubs present -> stubs complete -> unit tests -> package consumable -> release archive consumable

# The gate that must NEVER be satisfiable by an empty repository. It reads only committed
# files, so it needs neither Docker nor the submodules and cannot degrade into a skip: if the
# stubs are missing or the umbrella header points at a file that is not there, this fails.
check_stubs: ## Checks that the committed stubs are present and that public-api.h resolves against them
	@test -f public-api.h || { \
		echo "$(RED)[ERROR]$(NC) public-api.h is missing - the generated stubs are not committed"; \
		exit 1; \
	}
	@test -d api || { \
		echo "$(RED)[ERROR]$(NC) api/ is missing - the generated stubs are not committed"; \
		exit 1; \
	}
	@sources=`find api -type f -name "*.pb.cc" | grep -c . || true`; \
	headers=`find api -type f -name "*.pb.h" | grep -c . || true`; \
	includes=`sed -n 's|^#include "\(.*\.pb\.h\)"$$|\1|p' public-api.h | grep -c . || true`; \
	if [ "$$sources" -lt 1 ] || [ "$$headers" -lt 1 ]; then \
		echo "$(RED)[ERROR]$(NC) api/ holds no generated sources ($$sources .pb.cc / $$headers .pb.h)"; \
		exit 1; \
	fi; \
	if [ "$$includes" -lt 1 ]; then \
		echo "$(RED)[ERROR]$(NC) public-api.h includes no generated header"; \
		exit 1; \
	fi; \
	missing=0; \
	for header in `sed -n 's|^#include "\(.*\.pb\.h\)"$$|\1|p' public-api.h`; do \
		test -f "api/$$header" || { \
			echo "$(RED)[ERROR]$(NC) public-api.h includes $$header, but api/$$header does not exist"; \
			missing=1; \
		}; \
	done; \
	if [ "$$missing" != "0" ]; then exit 1; fi; \
	echo "$(GREEN)[SUCCESS]$(NC) $$sources generated sources, $$headers headers, all $$includes public-api.h includes resolve"

# Every .proto under ondewo-vtsi-api/ondewo must have produced a <name>.pb.h. Degrades to a labelled
# skip when the API submodule is not checked out, so a `make test` on a bare checkout (CI without
# submodule access) still runs the smoke test instead of dying on a missing directory.
check_build: ## Checks that every ONDEWO .proto produced generated C++ code
	@if [ ! -d "$(ONDEWO_API_DIR)/$(ONDEWO_PROTOS_SUBDIR)" ]; then \
		echo "$(YELLOW)[NOOP]$(NC) $(ONDEWO_API_DIR)/$(ONDEWO_PROTOS_SUBDIR) is not checked out - run 'make update_submodules'; skipping check_build"; \
		exit 0; \
	fi; \
	if [ ! -d api ]; then \
		echo "$(RED)[ERROR]$(NC) no api/ directory - run 'make generate_ondewo_protos' first"; \
		exit 1; \
	fi; \
	missing=0; \
	for proto in `find $(ONDEWO_API_DIR)/$(ONDEWO_PROTOS_SUBDIR) -type f -name "*.proto"`; do \
		header="`basename "$$proto" .proto`.pb.h"; \
		find api -type f -name "$$header" | grep -q . || { \
			echo "$(RED)[ERROR]$(NC) No C++ code generated for $$proto (expected api/**/$$header)"; \
			missing=1; \
		}; \
	done; \
	if [ "$$missing" != "0" ]; then exit 1; fi; \
	echo "$(GREEN)[SUCCESS]$(NC) Generated C++ code found for every .proto"

# Consumes the installed CMake package exactly the way a downstream application does - the one
# check that proves find_package(), the exported target, the umbrella header and the link line all
# work together. Everything is written into a throwaway directory; nothing is added to the repo.
smoke_test: ## Compile and run a tiny program against the installed CMake package
	@test -d "lib/cmake/$(LIBRARY_NAME)" || { \
		echo "$(RED)[ERROR]$(NC) lib/cmake/$(LIBRARY_NAME)/ is missing - run 'make build_library' first"; \
		exit 1; \
	}
	@rm -rf $(SMOKE_TEST_DIR)
	@mkdir -p $(SMOKE_TEST_DIR)
	@printf '%s\n' \
		'#include "public-api.h"' \
		'#include <ondewo/client/channel.h>' \
		'#include <google/protobuf/stubs/common.h>' \
		'#include <cstdio>' \
		'int main() {' \
		'  GOOGLE_PROTOBUF_VERIFY_VERSION;' \
		'  ondewo::client::DefaultChannelArguments();' \
		'  std::puts("ondewo-vtsi-client-cpp smoke test OK");' \
		'  google::protobuf::ShutdownProtobufLibrary();' \
		'  return 0;' \
		'}' > $(SMOKE_TEST_DIR)/main.cpp
	@printf '%s\n' \
		'cmake_minimum_required(VERSION 3.22)' \
		'project(ondewo_client_smoke_test LANGUAGES CXX)' \
		'set(CMAKE_CXX_STANDARD 17)' \
		'set(CMAKE_CXX_STANDARD_REQUIRED ON)' \
		'find_package($(LIBRARY_NAME) CONFIG REQUIRED)' \
		'add_executable(smoke_test main.cpp)' \
		'target_link_libraries(smoke_test PRIVATE ondewo::$(LIBRARY_NAME))' \
		> $(SMOKE_TEST_DIR)/CMakeLists.txt
	cmake -S $(SMOKE_TEST_DIR) -B $(SMOKE_TEST_DIR)/build -DCMAKE_PREFIX_PATH="$(INSTALL_PREFIX)"
	cmake --build $(SMOKE_TEST_DIR)/build --parallel $(BUILD_JOBS)
	./$(SMOKE_TEST_DIR)/build/smoke_test
	@rm -rf $(SMOKE_TEST_DIR)
	@echo "$(GREEN)[SUCCESS]$(NC) The installed CMake package is consumable"

# The GoogleTest suite. It links against the INSTALLED package, so `make build_library` (or a
# `make build`) has to have run first - that is also what makes it a consumer-level test.
unit_test: ## Build and run the GoogleTest/CTest suite against the installed package
	@test -d "lib/cmake/$(LIBRARY_NAME)" || { \
		echo "$(RED)[ERROR]$(NC) lib/cmake/$(LIBRARY_NAME)/ is missing - run 'make build_library' first"; \
		exit 1; \
	}
	@echo "$(BLUE)[INFO]$(NC) Building the test suite ..."
	cmake -S $(TEST_DIR) -B $(TEST_BUILD_DIR) \
		-DCMAKE_BUILD_TYPE=Debug \
		-DCMAKE_PREFIX_PATH="$(INSTALL_PREFIX)" \
		-DONDEWO_LIBRARY_NAME=$(LIBRARY_NAME) \
		-DONDEWO_ENABLE_COVERAGE=$(ONDEWO_ENABLE_COVERAGE)
	cmake --build $(TEST_BUILD_DIR) --parallel $(BUILD_JOBS)
	ctest --test-dir $(TEST_BUILD_DIR) --output-on-failure
	@echo "$(GREEN)[SUCCESS]$(NC) The test suite passed"

# Default OFF so a plain `make unit_test` builds optimised, uninstrumented binaries; the
# coverage target below turns it on.
ONDEWO_ENABLE_COVERAGE?=OFF

# Measures HAND-WRITTEN code only. The gcovr filter is tests/ and client/ and nothing else, and the client
# archive was compiled without --coverage, so no generated *.pb.cc can contribute a line either
# way. Anything below $(COVERAGE_MIN) % lines fails the build.
coverage: ## Run the test suite under gcov and fail if hand-written line coverage drops below COVERAGE_MIN
	@command -v gcovr >/dev/null 2>&1 || { \
		echo "$(RED)[ERROR]$(NC) gcovr is not installed - 'pip install gcovr' or 'apt-get install gcovr'"; \
		exit 1; \
	}
	@rm -rf $(TEST_BUILD_DIR)
	@$(MAKE) unit_test ONDEWO_ENABLE_COVERAGE=ON
	@echo "$(BLUE)[INFO]$(NC) Measuring coverage of the hand-written sources under $(TEST_DIR)/ ..."
# The report is printed even when the threshold is not met - the table naming the uncovered
# lines is exactly what is needed then, so the exit code is captured and re-raised afterwards.
	@gcovr --root . --filter '$(TEST_DIR)/' --filter 'client/' --print-summary --txt coverage.txt \
		--fail-under-line $(COVERAGE_MIN) $(TEST_BUILD_DIR); \
	status=$$?; cat coverage.txt; exit $$status
	@echo "$(GREEN)[SUCCESS]$(NC) Hand-written line coverage is at least $(COVERAGE_MIN) %"

########################################################
#		Submodules

update_submodules: ## Initialize and update all submodules
	@echo "$(BLUE)[INFO]$(NC) START initializing submodules ..."
	git submodule update --init --recursive
	@echo "$(GREEN)[SUCCESS]$(NC) DONE initializing submodules"

checkout_defined_submodule_versions: update_submodules ## Check out the submodule versions pinned in the Variables chapter
	@echo "$(BLUE)[INFO]$(NC) START checking out submodules ..."
	git -C $(ONDEWO_API_DIR) fetch --all
	git -C $(ONDEWO_API_DIR) checkout ${ONDEWO_VTSI_API_GIT_BRANCH}
	git -C $(ONDEWO_PROTO_COMPILER_DIR) fetch --all
	git -C $(ONDEWO_PROTO_COMPILER_DIR) checkout ${ONDEWO_PROTO_COMPILER_GIT_BRANCH}
	@echo "$(GREEN)[SUCCESS]$(NC) DONE checking out submodules"

########################################################
#		Release

# The order is the contract every ONDEWO VTSI client shares, pinned by tests/test_release_order.sh:
#   release_preflight -> build -> FULL test suite -> commit -> push -> release branch -> tag
#   -> GitHub release -> release_verify
# Nothing that cannot be taken back (a push, a branch or tag on origin, a GitHub release) happens
# before every check that can be refuted locally has passed: `spc` refuses every retry for as long
# as the branch and the tag exist, and a published tag is what consumers pin.
#
# The registry of this client is the GitHub release asset, and its ONLY uploader is
# .github/workflows/release.yml, started by the tag push: it builds the archive on the pinned
# ubuntu-24.04 runner, so every release carries the same linux-x86_64 asset whichever machine cut
# it. The local release used to upload as well, both with --clobber, and since archives are not
# byte-reproducible two interleaved uploads could leave a tarball and a .sha256 from different
# builders. The publish therefore necessarily happens AFTER the tag, so release_verify comes last
# and waits for that upload.
release: ## Automate the entire release process (credential in GITHUB_GH_TOKEN; `make ondewo_release` reads it)
	@echo "$(BLUE)[INFO]$(NC) Start Release"
	make release_preflight
	make checkout_defined_submodule_versions build_compiler generate_ondewo_protos
	make $(call toolchain,build_library)
	-make precommit_hooks_run_all_files
# The FULL gate: committed stubs, every .proto generated, the GoogleTest/CTest suite (including the
# release-notes, release-hygiene and release-order script tests), the package smoke test and the
# packaging dry-run that builds the archive and consumes it - all before the first commit.
	make $(call toolchain,test)
	git status
# api/, public-api.h and the two generated build files are COMMITTED on purpose: C++ has no
# package registry, so the git tag is this client's only distribution channel and a consumer must
# get a buildable CMake project from a plain clone. See the note in .gitignore.
	git add api
	git add public-api.h
	-git add CMakeLists.txt
	-git add ondewo-client-config.cmake.in
	git add Makefile
	git add README.md
	git add RELEASE.md
	git add $(ONDEWO_PROTO_COMPILER_DIR)
	git add $(ONDEWO_API_DIR)
	git status
# Commit only when something is staged, but never swallow a REAL commit failure (e.g. no git
# identity): with `-git commit` the tag below would silently name the previous commit.
	git diff --cached --quiet || git commit --no-verify -m "Preparing for Release ${ONDEWO_VTSI_VERSION}"
	git push
	make create_release_branch
	make create_release_tag
	make build_gh_release
	make release_verify
	@echo "$(GREEN)[SUCCESS]$(NC) Release Finished"

create_release_branch: ## Create Release Branch and push it to origin
	git checkout -b "release/${ONDEWO_VTSI_VERSION}"
	git push -u origin "release/${ONDEWO_VTSI_VERSION}"

create_release_tag: ## Create Release Tag and push it to origin
	git tag -a ${ONDEWO_VTSI_VERSION} -m "release/${ONDEWO_VTSI_VERSION}"
	git push origin ${ONDEWO_VTSI_VERSION}

# Read-only: changes nothing locally that is tracked, and nothing on origin or on GitHub. Each check
# refutes something that would otherwise only fail after the tag is on origin.
release_preflight: check_host_tools check_release_notes check_gh_token_valid check_version_unreleased ## Read-only release gate: host tools, release notes, token valid with push rights, version not yet released
	@echo "$(GREEN)[SUCCESS]$(NC) release preflight passed for $(ONDEWO_VTSI_VERSION) - nothing was changed"

# docker runs the proto compiler, the C++ toolchain when cmake is absent, and gh; perl slices the
# release notes. cmake, gh and sha256sum are NOT required on the host.
check_host_tools: ## Assert the host tools the release needs exist: docker (with a reachable daemon), make, git, perl
	@missing=""; \
	for tool in docker make git perl; do \
		command -v "$$tool" >/dev/null 2>&1 || missing="$$missing $$tool"; \
	done; \
	if [ -n "$$missing" ]; then \
		echo "$(RED)[ERROR]$(NC) the release needs these host tools, which are missing:$$missing"; \
		exit 1; \
	fi
	@docker info >/dev/null 2>&1 || { \
		echo "$(RED)[ERROR]$(NC) docker is installed but its daemon is not reachable - the release runs the compiler, the toolchain and gh in containers"; \
		exit 1; \
	}
	@echo "$(GREEN)[SUCCESS]$(NC) host tools present: docker make git perl"

check_release_credentials: ## Fail loudly when the GitHub release credential is unset or still the placeholder
# The value is only ever tested, never printed - not even partially. The placeholder counts as
# unset: `$(if $(GITHUB_GH_TOKEN),...)` alone reports the default ENTER_YOUR_TOKEN_HERE as "set".
	@$(LOAD_RELEASE_CREDENTIALS); \
	if [ -z "$${GITHUB_GH_TOKEN}" ] || [ "$${GITHUB_GH_TOKEN}" = "ENTER_YOUR_TOKEN_HERE" ]; then \
		echo "$(RED)[ERROR]$(NC) refusing to release - GITHUB_GH_TOKEN is not set"; \
		echo "        use 'make ondewo_release', which reads it from $(DEVOPS_ACCOUNT_GIT)/account_github.env,"; \
		echo "        or create a token at https://github.com/settings/tokens and export GITHUB_GH_TOKEN"; \
		exit 1; \
	fi
	@echo "$(GREEN)[SUCCESS]$(NC) the GitHub release credential is set"

gh_image: ## Build the pinned GitHub CLI image (gh.Dockerfile) every gh call of the release runs in
	@docker build -q -t $(GH_IMAGE) - < gh.Dockerfile >/dev/null
	@echo "$(GREEN)[SUCCESS]$(NC) $(GH_IMAGE) is available"

# A set token is not a valid one. GET /repos/<owner>/<repo> changes nothing; `.permissions` is only
# present for an authenticated caller, and `push` is exactly what the release branch, the tag and
# the GitHub release need. GH_TOKEN is set from GITHUB_GH_TOKEN for this one command, so a stale
# GH_TOKEN / GITHUB_TOKEN of the host can neither stand in for the release token nor shadow it.
check_gh_token_valid: check_release_credentials gh_image ## Assert GitHub accepts GITHUB_GH_TOKEN and lets it push to this repository (read-only)
	@$(LOAD_RELEASE_CREDENTIALS); \
	push=$$(GH_TOKEN="$$GITHUB_GH_TOKEN" $(GH_RUN) gh api "repos/$(GH_REPO_PATH)" --jq .permissions.push) \
		|| { echo "$(RED)[ERROR]$(NC) GitHub refused GITHUB_GH_TOKEN (see the gh error above)"; exit 1; }; \
	if [ "$$push" != "true" ]; then \
		echo "$(RED)[ERROR]$(NC) GITHUB_GH_TOKEN is valid but may not push to $(GH_REPO_PATH) (permissions.push=$$push)"; \
		exit 1; \
	fi
	@echo "$(GREEN)[SUCCESS]$(NC) GitHub accepts GITHUB_GH_TOKEN and it may push to $(GH_REPO_PATH)"

# The version must not exist on ORIGIN yet - `spc` only sees the local refs - and must not have a
# GitHub release (this client's registry). `git ls-remote --exit-code` matches the full ref names
# exactly (exit 2 = no match), and gh's "release not found" is the only answer that means "free".
check_version_unreleased: check_release_credentials gh_image ## Assert the version is neither a tag/release branch on origin nor a GitHub release (read-only)
	@status=0; refs=$$(git ls-remote --exit-code origin "refs/tags/$(ONDEWO_VTSI_VERSION)" "refs/heads/release/$(ONDEWO_VTSI_VERSION)") || status=$$?; \
	case "$$status" in \
		0) echo "$(RED)[ERROR]$(NC) $(ONDEWO_VTSI_VERSION) already exists on origin:"; echo "$$refs"; exit 1 ;; \
		2) echo "$(GREEN)[SUCCESS]$(NC) neither refs/tags/$(ONDEWO_VTSI_VERSION) nor refs/heads/release/$(ONDEWO_VTSI_VERSION) exists on origin" ;; \
		*) echo "$(RED)[ERROR]$(NC) cannot list the refs of origin (git ls-remote exit $$status)"; exit 1 ;; \
	esac
	@$(LOAD_RELEASE_CREDENTIALS); \
	if out=$$(GH_TOKEN="$$GITHUB_GH_TOKEN" $(GH_RUN) gh release view "$(ONDEWO_VTSI_VERSION)" --repo "$(GH_REPO_PATH)" --json tagName 2>&1); then \
		echo "$(RED)[ERROR]$(NC) a GitHub release $(ONDEWO_VTSI_VERSION) already exists on $(GH_REPO_PATH)"; \
		exit 1; \
	fi; \
	case "$$out" in \
		*"release not found"*) echo "$(GREEN)[SUCCESS]$(NC) no GitHub release $(ONDEWO_VTSI_VERSION) yet" ;; \
		*) echo "$(RED)[ERROR]$(NC) cannot query the GitHub releases of $(GH_REPO_PATH): $$out"; exit 1 ;; \
	esac

check_release_notes: ## Assert RELEASE.md carries a non-empty entry headed exactly 'Release ONDEWO VTSI C++ Client <version>'
# $(CURRENT_RELEASE_NOTES) is a perl flip-flop over RELEASE.md, so a forgotten entry - or a
# heading whose wording drifted away from what that flip-flop greps for - slices to the empty
# string. `gh release create -n ""` does not complain about that: it succeeds and publishes an
# EMPTY release. The heading line alone (an entry with no content) is refused as well.
	@notes="$(CURRENT_RELEASE_NOTES)"; \
	content=$$(printf '%s\n' "$$notes" | sed '1d' | grep -v '^\*\{5\}' | grep -c '[^[:space:]]' || true); \
	if [ -z "$$notes" ] || [ "$$content" -lt 1 ]; then \
		echo "$(RED)[ERROR]$(NC) RELEASE.md has no non-empty '## Release ONDEWO VTSI C++ Client ${ONDEWO_VTSI_VERSION}' entry"; \
		echo "        The GitHub release would be created with empty notes - add the entry first."; \
		exit 1; \
	fi; \
	echo "$(GREEN)[SUCCESS]$(NC) RELEASE.md has release notes for ${ONDEWO_VTSI_VERSION}"

# The guard is a prerequisite, not just a step of `release`, so that a hand-run
# `make build_gh_release` cannot publish an empty release either. The notes reach gh on stdin.
build_gh_release: check_release_notes check_release_credentials gh_image ## Create the GitHub release with the RELEASE.md notes (gh in GH_IMAGE)
	@$(LOAD_RELEASE_CREDENTIALS); \
	printf '%s\n' "$(CURRENT_RELEASE_NOTES)" | GH_TOKEN="$$GITHUB_GH_TOKEN" $(GH_RUN) \
		gh release create --repo "$(GH_REPO_PATH)" "$(ONDEWO_VTSI_VERSION)" --notes-file - --title "Release ${ONDEWO_VTSI_VERSION}"

# Read-only. The tag is on origin, the GitHub release has a non-empty body, and the archive the
# release workflow attached downloads and passes `sha256sum -c` (tools/verify_release_asset.sh,
# the same script release.yml runs after its upload; it waits up to 20 min for the asset and stops
# at once if the tag's release run failed). VERIFY_ATTEMPTS / VERIFY_INTERVAL_S bound that wait
# (`make release_verify VERIFY_ATTEMPTS=3 VERIFY_INTERVAL_S=10`, as the release driver runs it);
# `-e NAME` without a value forwards them only when set, so the script's defaults apply otherwise.
release_verify: check_release_credentials gh_image ## Verify the published release: tag on origin, non-empty notes, archive attached and matching its sha256
	@git ls-remote --exit-code origin "refs/tags/$(ONDEWO_VTSI_VERSION)" >/dev/null || { \
		echo "$(RED)[ERROR]$(NC) the tag $(ONDEWO_VTSI_VERSION) is not on origin"; \
		exit 1; \
	}
	@echo "$(GREEN)[SUCCESS]$(NC) refs/tags/$(ONDEWO_VTSI_VERSION) is on origin"
	@$(LOAD_RELEASE_CREDENTIALS); \
	GH_TOKEN="$$GITHUB_GH_TOKEN" docker run --rm -i --user "`id -u`:`id -g`" -e HOME=/tmp -e GH_TOKEN \
		-e VERIFY_ATTEMPTS -e VERIFY_INTERVAL_S $(GH_IMAGE) \
		sh -s -- "$(ONDEWO_VTSI_VERSION)" "$(GH_REPO_PATH)" "$(LIBRARY_NAME)" < tools/verify_release_asset.sh

########################################################
#		PACKAGE

# C++ has no registry to push to, so "publishing" is: stage -> archive -> verify -> attach to the
# GitHub release. The GitHub release asset IS the package; the sibling clients' PyPI/npm chapters
# sit in exactly this slot of their Makefiles.
#
#   make publish_dry_run   everything except the upload - no credentials, part of `make test`, so it
#                          runs in CI on every push and in `make release` before the first commit
#   make upload_package    the upload itself - run ONLY by .github/workflows/release.yml from the tag
#                          push, which makes the workflow this client's single uploader
#   make release_verify    downloads what was attached and checks it with `sha256sum -c`
#
# There is no `make publish` any more: a second uploader next to the workflow raced it.

# The credential-free packaging gate: if the archive cannot be built, or cannot be consumed once
# extracted, that fails here rather than during a release.
publish_dry_run: build_package verify_package ## Build the release archive and consume it after extraction - no credentials, uploads nothing
	@echo "$(BLUE)[INFO]$(NC) the release workflow would attach $(PACKAGE_ARCHIVE) and $(PACKAGE_ARCHIVE).sha256"
	@echo "$(GREEN)[SUCCESS]$(NC) Packaging dry-run complete - nothing was uploaded"

build_package: ## Stage the install tree into dist/<library>-<version>-<platform>.tar.gz and checksum it
	@test -d $(BUILD_DIR) || { \
		echo "$(RED)[ERROR]$(NC) no $(BUILD_DIR)/ build tree - run 'make build_library' first"; \
		exit 1; \
	}
	@rm -rf $(PACKAGE_STAGE_DIR) $(PACKAGE_ARCHIVE) $(PACKAGE_ARCHIVE).sha256
	@mkdir -p $(PACKAGE_STAGE_DIR)
	@echo "$(BLUE)[INFO]$(NC) Staging $(PACKAGE_NAME) ..."
# --prefix overrides CMAKE_INSTALL_PREFIX at install time (CMake >= 3.15), so the staged tree is
# self-contained: configure_package_config_file() and install(EXPORT) only ever emit paths relative
# to the installed config file, which is what lets a consumer extract the archive anywhere.
	cmake --install $(BUILD_DIR) --prefix $(PACKAGE_STAGE_DIR)
	cp LICENSE README.md RELEASE.md $(PACKAGE_STAGE_DIR)/
# Provenance for a BINARY artifact: protobuf gives no cross-version guarantee between generated
# code and runtime, so a consumer has to be able to tell what this archive was compiled against.
	@{ \
		echo "name:        $(LIBRARY_NAME)"; \
		echo "version:     $(ONDEWO_VTSI_VERSION)"; \
		echo "platform:    $(PACKAGE_PLATFORM)"; \
		echo "protoc:      `protoc --version 2>/dev/null || echo unknown`"; \
		echo "libprotobuf: `pkg-config --modversion protobuf 2>/dev/null || echo unknown`"; \
		echo "libgrpc++:   `pkg-config --modversion grpc++ 2>/dev/null || echo unknown`"; \
		echo "compiler:    `$(CXX) --version 2>/dev/null | head -1 || echo unknown`"; \
	} > $(PACKAGE_STAGE_DIR)/PACKAGE-INFO.txt
	tar -czf $(PACKAGE_ARCHIVE) -C $(PACKAGE_DIR) $(PACKAGE_NAME)
# sha256sum is GNU coreutils; macOS ships shasum instead. Both print "<hash>  <file>", so the
# checksum file is verified the same way on either side: `cd $(PACKAGE_DIR) && sha256sum -c ...`.
	@cd $(PACKAGE_DIR) && if command -v sha256sum >/dev/null 2>&1; then \
		sha256sum $(PACKAGE_NAME).tar.gz > $(PACKAGE_NAME).tar.gz.sha256; \
	else \
		shasum -a 256 $(PACKAGE_NAME).tar.gz > $(PACKAGE_NAME).tar.gz.sha256; \
	fi
# The staged directory is removed again: the tarball is the artifact, and leaving an unpacked copy
# of it beside the one verify_package extracts would only invite consuming the wrong tree.
	@rm -rf $(PACKAGE_STAGE_DIR)
	@echo "$(GREEN)[SUCCESS]$(NC) `du -h $(PACKAGE_ARCHIVE) | awk '{print $$1}'` $(PACKAGE_ARCHIVE)"
	@cat $(PACKAGE_ARCHIVE).sha256

# THE test that makes the release archive worth publishing. It extracts the tarball into a
# throwaway tree and builds tests/package-consume against it - an unrelated CMake project that
# find_package()es the extracted archive, includes the umbrella header and links the exported
# ondewo:: target. Needs no credentials and uploads nothing, so CI runs it on every push.
verify_package: ## Extract the release archive and consume it with find_package() from an unrelated CMake project
	@test -f $(PACKAGE_ARCHIVE) || { \
		echo "$(RED)[ERROR]$(NC) $(PACKAGE_ARCHIVE) does not exist - run 'make build_package' first"; \
		exit 1; \
	}
	@rm -rf $(PACKAGE_TEST_DIR)
	@mkdir -p $(PACKAGE_TEST_DIR)
	@cd $(PACKAGE_DIR) && if command -v sha256sum >/dev/null 2>&1; then \
		sha256sum -c $(PACKAGE_NAME).tar.gz.sha256; \
	else \
		shasum -a 256 -c $(PACKAGE_NAME).tar.gz.sha256; \
	fi
	tar -xzf $(PACKAGE_ARCHIVE) -C $(PACKAGE_TEST_DIR)
# Every file a consumer is promised. Without this the consume build below could still succeed
# against a half-empty archive that happens to carry enough to link.
	@for f in PACKAGE-INFO.txt LICENSE \
			include/$(LIBRARY_NAME)/public-api.h \
			lib/lib$(LIBRARY_NAME).a \
			lib/cmake/$(LIBRARY_NAME)/$(LIBRARY_NAME)-config.cmake \
			lib/cmake/$(LIBRARY_NAME)/$(LIBRARY_NAME)-config-version.cmake \
			lib/cmake/$(LIBRARY_NAME)/$(LIBRARY_NAME)-targets.cmake; do \
		test -f "$(PACKAGE_TEST_DIR)/$(PACKAGE_NAME)/$$f" || { \
			echo "$(RED)[ERROR]$(NC) the release archive is missing $$f"; \
			exit 1; \
		}; \
	done
# The per-configuration half of the exported target set. Its name carries the build type
# ($(LIBRARY_NAME)-targets-release.cmake), so it is matched rather than named: without it
# find_package() still succeeds but the imported target has no archive to point at.
	@configs=`find $(PACKAGE_TEST_DIR)/$(PACKAGE_NAME)/lib/cmake/$(LIBRARY_NAME) -type f -name "$(LIBRARY_NAME)-targets-*.cmake" | grep -c . || true`; \
	if [ "$$configs" -lt 1 ]; then \
		echo "$(RED)[ERROR]$(NC) the release archive ships no $(LIBRARY_NAME)-targets-<config>.cmake"; \
		exit 1; \
	fi
	@packaged=`find $(PACKAGE_TEST_DIR)/$(PACKAGE_NAME)/include -type f -name "*.pb.h" | grep -c . || true`; \
	built=`find api -type f -name "*.pb.h" | grep -c . || true`; \
	if [ "$$packaged" != "$$built" ]; then \
		echo "$(RED)[ERROR]$(NC) the release archive ships $$packaged headers but api/ holds $$built"; \
		exit 1; \
	fi; \
	echo "$(BLUE)[INFO]$(NC) archive holds $$packaged generated headers, all package files present"
# CMAKE_PREFIX_PATH is the extracted archive and nothing else; ONDEWO_PACKAGE_PREFIX makes the
# consume project assert that find_package() really resolved there, so a stale system-wide or
# repository-root install tree cannot stand in for the archive under test.
	cmake -S $(PACKAGE_CONSUME_DIR) -B $(PACKAGE_TEST_DIR)/build \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_PREFIX_PATH="$(CURDIR)/$(PACKAGE_TEST_DIR)/$(PACKAGE_NAME)" \
		-DONDEWO_PACKAGE_PREFIX="$(CURDIR)/$(PACKAGE_TEST_DIR)/$(PACKAGE_NAME)" \
		-DONDEWO_LIBRARY_NAME=$(LIBRARY_NAME)
	cmake --build $(PACKAGE_TEST_DIR)/build --parallel $(BUILD_JOBS)
	./$(PACKAGE_TEST_DIR)/build/package_consume
	@rm -rf $(PACKAGE_TEST_DIR)
	@echo "$(GREEN)[SUCCESS]$(NC) $(PACKAGE_NAME).tar.gz is consumable with find_package($(LIBRARY_NAME)) after extraction"

# Run by .github/workflows/release.yml ONLY (the single uploader - see the Release chapter), with
# the runner's gh and GH_TOKEN from the ONDEWO_GH_TOKEN repository secret in its environment; no
# token is ever named on this command line. GH_TOKEN is exported to this one recipe because the
# global `unexport` keeps it from every other one. --clobber so a re-run of the workflow after a
# fixed build replaces its own asset instead of failing.
upload_package: ## CI only (release.yml): attach the release archive and its checksum to the GitHub release
	@test -f $(PACKAGE_ARCHIVE) || { \
		echo "$(RED)[ERROR]$(NC) $(PACKAGE_ARCHIVE) does not exist - run 'make build_package' first"; \
		exit 1; \
	}
	gh release upload --repo $(GH_REPO) --clobber "$(ONDEWO_VTSI_VERSION)" \
		$(PACKAGE_ARCHIVE) $(PACKAGE_ARCHIVE).sha256

########################################################
#		GITHUB

# No `gh auth login` anywhere: it stored the token in ~/.config/gh/hosts.yml on the release host and
# needed a host gh. Every gh call runs in GH_IMAGE with GH_TOKEN for that one call.
push_to_gh: build_gh_release ## Create the GitHub release (alias of build_gh_release)
	@echo 'Released to Github'

########################################################
#		DEVOPS-ACCOUNTS

ondewo_release: spc run_release_with_devops ## Release with credentials from the devops-accounts repo

# Where the credentials come from:
#   - DEVOPS_ACCOUNT_DIR (environment) names an existing directory: the caller's clone - e.g. the
#     single temp clone of the release driver in ondewo-vtsi-api - is read and left in place, it
#     belongs to the caller;
#   - otherwise the repo is cloned into a fresh `mktemp -d` OUTSIDE this repository, so it is never
#     inside a directory mounted into the compiler, toolchain or gh containers.
# The own clone is DELETED right after the token is read - before `$(MAKE) release`, which needs
# only the value, now in the environment - and by the EXIT trap when anything before that fails.
# The credential is exported into the sub-make's ENVIRONMENT. `make release NAME=<value>` would put
# its value on make's argv, which /proc/<pid>/cmdline shows to every user on the host; the grep is
# anchored so that a comment mentioning the name cannot replace the value.
run_release_with_devops: ## Read the credential from devops-accounts, delete the clone, then run the full release
	@set -eu; \
	if [ -n "$(MAKE_DRY_RUN)" ]; then \
		echo "$(BLUE)[INFO]$(NC) dry run (make -n): no credentials are read and nothing is cloned"; \
		$(MAKE) release; \
		exit 0; \
	fi; \
	owned=""; \
	if [ -n "$${DEVOPS_ACCOUNT_DIR:-}" ] && [ -d "$${DEVOPS_ACCOUNT_DIR}" ]; then \
		accounts="$${DEVOPS_ACCOUNT_DIR}"; \
		echo "$(BLUE)[INFO]$(NC) reading the credentials from DEVOPS_ACCOUNT_DIR (the caller's clone, left in place)"; \
	else \
		accounts="$$(mktemp -d)"; \
		owned="$$accounts"; \
		trap 'rm -rf "$$owned"' EXIT; \
		trap 'exit 1' HUP INT TERM; \
		$(DEVOPS_ACCOUNT_CLONE) "$$accounts"; \
	fi; \
	grep -q -E '^GITHUB_GH_TOKEN=' "$$accounts/account_github.env" || { \
		echo "$(RED)[ERROR]$(NC) $(DEVOPS_ACCOUNT_GIT)/account_github.env carries no GITHUB_GH_TOKEN="; \
		exit 1; \
	}; \
	set -a; \
	eval "$$(grep -h -E '^GITHUB_GH_TOKEN=' "$$accounts/account_github.env")"; \
	set +a; \
	if [ -n "$$owned" ]; then \
		rm -rf "$$owned"; \
		echo "$(BLUE)[INFO]$(NC) the $(DEVOPS_ACCOUNT_GIT) clone is deleted - only the token in the environment is left"; \
	fi; \
	$(MAKE) release

spc: ## Checks if the Release Branch and Tag already exist
	$(eval filtered_branches:= $(shell git branch --all | grep -E "(^|[ /])release/$(subst .,\.,${ONDEWO_VTSI_VERSION})$$"))
	$(eval filtered_tags:= $(shell git tag --list | grep -Fx "${ONDEWO_VTSI_VERSION}"))
	@if test "$(filtered_branches)" != ""; then echo "-- Test 1: Branch exists!!" && exit 1; else echo "-- Test 1: Branch is fine";fi
	@if test "$(filtered_tags)" != ""; then echo "-- Test 2: Tag exists!!" && exit 1; else echo "-- Test 2: Tag is fine";fi
