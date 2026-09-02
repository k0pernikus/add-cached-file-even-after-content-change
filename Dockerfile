# syntax=docker/dockerfile:1
FROM scratch

ARG SRC_URL
ARG SRC_SHA256

ADD --checksum=sha256:${SRC_SHA256} ${SRC_URL} /payload
