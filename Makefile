.DEFAULT_GOAL := help

IMAGE   := pixel-agents-adt
NAME    := pixel-agents-adt
PORT_PIXEL := 3100
PORT_NODERED := 1881

.PHONY: help build run stop logs clean

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /|/' | awk -F'|' '{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

build: ## Build the image
	docker build -t $(IMAGE) .

run: ## Run the container (needs GH_TOKEN from a `gh auth login`'d host; see AGENTS.md for the flag rationale)
	docker rm -f $(NAME) 2>/dev/null || true
	docker run -d --name $(NAME) \
		--cap-add=SYS_ADMIN --cap-add=NET_ADMIN \
		--security-opt seccomp=unconfined --security-opt apparmor=unconfined \
		-p $(PORT_PIXEL):3100 -p $(PORT_NODERED):1881 \
		-e GH_TOKEN="$$(gh auth token)" \
		$(IMAGE)
	@echo "pixel-agents:  http://localhost:$(PORT_PIXEL)"
	@echo "ADT dashboard: http://localhost:$(PORT_NODERED)/dashboard/adt"

stop: ## Stop and remove the running container
	docker rm -f $(NAME) 2>/dev/null || true

logs: ## Follow the container's logs
	docker logs -f $(NAME)

clean: stop ## Stop the container and remove the built image
	docker rmi $(IMAGE) 2>/dev/null || true
