FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -o /out/symphonyd ./cmd/symphonyd

FROM alpine:3.21
RUN apk add --no-cache ca-certificates git openssh-client bash
WORKDIR /app
COPY --from=build /out/symphonyd /usr/local/bin/symphonyd
COPY examples/WORKFLOW.github.md /app/WORKFLOW.md
VOLUME ["/data/workspaces", "/data/db"]
CMD ["symphonyd", "run", "--workflow", "/app/WORKFLOW.md", "--port", "4000"]
