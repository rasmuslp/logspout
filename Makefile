NAME=logspout
VERSION=$(shell cat VERSION)
# max image size of 40MB
MAX_IMAGE_SIZE := 40000000

GOBIN := $(shell go env GOPATH | awk -F ":" '{ print $$1 }')/bin
GOLANGCI_LINT_VERSION := v1.27.0

ifeq ($(shell uname), Darwin)
	XARGS_ARG="-L1"
endif
GOPACKAGES ?= $(shell go list ./... | egrep -v 'custom|vendor')
TEST_ARGS ?= -race

ifdef TEST_RUN
	TESTRUN := -run ${TEST_RUN}
endif

build-dev:
	docker build -f Dockerfile.dev -t $(NAME):dev .

dev: build-dev
	@docker run --rm \
		-e DEBUG=true \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v $(PWD):/go/src/github.com/gliderlabs/logspout \
		-p 8000:80 \
		-e ROUTE_URIS=$(ROUTE) \
		$(NAME):dev

build:
	mkdir -p build
	docker build -t $(NAME):$(VERSION) .
	docker save $(NAME):$(VERSION) | gzip -9 > build/$(NAME)_$(VERSION).tgz

build-custom:
	docker tag $(NAME):$(VERSION) gliderlabs/$(NAME):master
	cd custom && docker build -t $(NAME):custom .

lint-requirements:
ifeq ($(shell which golangci-lint), )
	curl -sfL https://install.goreleaser.com/github.com/golangci/golangci-lint.sh | sh -s -- -b $(GOBIN) $(GOLANGCI_LINT_VERSION)
endif

lint: lint-requirements
	$(GOBIN)/golangci-lint run

lint-ci-direct: lint-requirements
	$(GOBIN)/golangci-lint --verbose run

lint-ci: build-dev
	docker run \
		-v $(PWD):/go/src/github.com/gliderlabs/logspout \
		$(NAME):dev make -e lint-ci-direct

test: build-dev
	docker run \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v $(PWD):/go/src/github.com/gliderlabs/logspout \
		-e TEST_ARGS="" \
		-e DEBUG=$(DEBUG) \
		$(NAME):dev make -e test-direct

test-direct:
	go test -p 1 -v $(TEST_ARGS) $(GOPACKAGES) $(TESTRUN)

test-image-size:
	@if [ $(shell docker inspect -f '{{ .Size }}' $(NAME):$(VERSION)) -gt $(MAX_IMAGE_SIZE) ]; then \
		echo ERROR: image size greater than $(MAX_IMAGE_SIZE); \
		exit 2; \
	fi

test-tls:
	docker run -d --name $(NAME)-tls \
		-v /var/run/docker.sock:/var/run/docker.sock \
		$(NAME):$(VERSION) syslog+tls://logs3.papertrailapp.com:54202
	sleep 2
	docker logs $(NAME)-tls
	docker inspect --format='{{ .State.Running }}' $(NAME)-tls | grep true
	docker stop $(NAME)-tls || true
	docker rm $(NAME)-tls || true

test-healthcheck:
	docker run -d --name $(NAME)-healthcheck \
		-p 8000:80 \
		-v /var/run/docker.sock:/var/run/docker.sock \
		$(NAME):$(VERSION)
	sleep 5
	docker logs $(NAME)-healthcheck
	docker inspect --format='{{ .State.Running }}' $(NAME)-healthcheck | grep true
	curl --head --silent localhost:8000/health | grep "200 OK"
	docker stop $(NAME)-healthcheck || true
	docker rm $(NAME)-healthcheck || true

test-custom:
	docker run --name $(NAME)-custom $(NAME):custom || true
	docker logs $(NAME)-custom 2>&1 | grep -q logstash
	docker rmi gliderlabs/$(NAME):master || true
	docker rm $(NAME)-custom || true

test-tls-custom:
	docker run -d --name $(NAME)-tls-custom \
		-v /var/run/docker.sock:/var/run/docker.sock \
		$(NAME):custom syslog+tls://logs3.papertrailapp.com:54202
	sleep 2
	docker logs $(NAME)-tls-custom
	docker inspect --format='{{ .State.Running }}' $(NAME)-tls-custom | grep true
	docker stop $(NAME)-tls-custom || true
	docker rm $(NAME)-tls-custom || true

.PHONY: release
release:
	rm -rf release && mkdir release
	go get github.com/progrium/gh-release/...
	cp build/* release
	gh-release create gliderlabs/$(NAME) $(VERSION) \
		$(shell git rev-parse --abbrev-ref HEAD) $(VERSION)

.PHONY: circleci
circleci:
ifneq ($(CIRCLE_BRANCH), release)
	echo build-$$CIRCLE_BUILD_NUM > VERSION
endif

.PHONY: clean
clean:
	rm -rf build/
	docker rm $(shell docker ps -aq) || true
	docker rmi $(NAME):dev $(NAME):$(VERSION) || true
	docker rmi $(shell docker images -f 'dangling=true' -q) || true

.PHONY: publish-requirements
publish-requirements:
	mkdir -vp ~/.docker/cli-plugins/
	curl --silent -L --output ~/.docker/cli-plugins/docker-buildx https://github.com/docker/buildx/releases/download/v0.3.1/buildx-v0.3.1.linux-amd64
	chmod a+x ~/.docker/cli-plugins/docker-buildx
	docker run -it --rm --privileged tonistiigi/binfmt --install all
	docker buildx create --use --name mybuilder

.PHONY: publish-test
publish-test:
	docker buildx build --load --platform linux/amd64 -t gliderlabs/$(NAME):linux-amd64-${CIRCLE_BRANCH} .
	docker buildx build --load --platform linux/arm64 -t gliderlabs/$(NAME):linux-arm64-${CIRCLE_BRANCH} .
	docker images

.PHONY: publish-master
publish-master:
	docker buildx build --push --platform linux/arm64,linux/amd64 -t gliderlabs/$(NAME):master -t gliderlabs/$(NAME):latest .

.PHONY: publish-release
publish-release:
	docker buildx build --push --platform linux/arm64,linux/amd64 -t gliderlabs/$(NAME):$(VERSION) .
