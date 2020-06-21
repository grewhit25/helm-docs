FROM alpine as builder
RUN apk add -U go git build-base

RUN git clone -q --depth 1 https://github.com/norwoodj/helm-docs.git \
    /go/src/github.com/norwoodj/helm-docs
WORKDIR /go/src/github.com/norwoodj/helm-docs
RUN make helm-docs


FROM alpine

COPY --from=builder /go/src/github.com/norwoodj/helm-docs/helm-docs /usr/bin/

WORKDIR /helm-docs

ENTRYPOINT ["helm-docs"]
