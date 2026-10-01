FROM golang:1.25-alpine AS build
ARG PG_SCHEMA_DIFF_VERSION=latest
RUN GOBIN=/out go install github.com/stripe/pg-schema-diff/cmd/pg-schema-diff@${PG_SCHEMA_DIFF_VERSION}

FROM alpine:3.22
RUN apk add --no-cache ca-certificates
COPY --from=build /out/pg-schema-diff /usr/local/bin/pg-schema-diff
ENTRYPOINT ["pg-schema-diff"]
