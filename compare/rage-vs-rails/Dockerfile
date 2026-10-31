# Tools image for the Rage vs Rails comparison: Ubuntu 24.04 (like the benchmark box) with Ruby 4.0.9 built by the
# submissions' install.sh (both use the same one), Go (conformance suite, loadgen, seedgen), psql 18 and rsync.
# Build context: submissions/ruby-rage-cloetzi (only install.sh is used).
FROM ubuntu:24.04
ARG GO_VERSION=1.27.1
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -y -q --no-install-recommends curl ca-certificates gnupg rsync jq python3 \
      util-linux procps && \
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc && \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update -q && apt-get install -y -q --no-install-recommends postgresql-client-18 && \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz" | tar -xz -C /usr/local && \
    ln -s /usr/local/go/bin/go /usr/local/bin/go
COPY install.sh /tmp/install.sh
RUN bash /tmp/install.sh
