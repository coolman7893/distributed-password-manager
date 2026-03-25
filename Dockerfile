FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /master  ./cmd/master
RUN CGO_ENABLED=0 go build -o /chunk   ./cmd/chunkserver
RUN CGO_ENABLED=0 go build -o /client  ./cmd/client

FROM alpine:3.19
RUN apk add --no-cache ca-certificates
COPY --from=builder /master /chunk /client /usr/local/bin/
COPY certs/ /certs/
ENTRYPOINT ["/bin/sh"]
