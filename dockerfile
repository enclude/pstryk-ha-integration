FROM debian:stable-slim

RUN apt-get update && \
    apt-get install -y curl jq && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY ha.sh /app/ha.sh

RUN chmod +x /app/ha.sh

CMD ["/app/ha.sh"]