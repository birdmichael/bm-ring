# push-server — personal APNs buzz relay.
# Build:  docker build -t bm-ring-push .
# Run:    docker run -d --name push --restart unless-stopped \
#           -p 127.0.0.1:8902:8902 \
#           -v /path/to/your/config.json:/app/config.json:ro \
#           -v /path/to/AuthKey_XXXX.p8:/app/AuthKey_XXXX.p8:ro \
#           bm-ring-push
# NOTE: the .p8 path INSIDE the container must match "p8_path" in config.json
# (e.g. "/app/AuthKey_XXXX.p8"). Keep the key file read-only and root-owned.

FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

# Run as non-root; the mounted config/key just need to be readable.
RUN useradd -m relay && chown -R relay:relay /app
USER relay

EXPOSE 8902

CMD ["python", "server.py"]
