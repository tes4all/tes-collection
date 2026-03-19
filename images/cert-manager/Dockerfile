# Stage 0: Get Lego
FROM goacme/lego:v4.33.0 AS lego-source

# Stage 1: Build Python Venv
FROM python:3.14.3-slim-trixie AS builder
COPY --from=ghcr.io/astral-sh/uv:0.9 /uv /bin/

RUN apt-get update && apt-get -y upgrade && apt-get install -y python3-dev gcc build-essential

WORKDIR /packages
COPY requirements.txt .

ENV PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1

RUN uv venv .venv && \
    uv pip install --no-cache -r requirements.txt

# Stage 2: Final Image
FROM python:3.14.3-slim-trixie

RUN apt-get update && apt-get -y upgrade && \
    apt-get install -y ca-certificates git gosu && \
    rm -rf /var/lib/apt/lists/*

# Copy Lego binary
COPY --from=lego-source /lego /usr/bin/lego

# Copy Venv
COPY --from=builder /packages/.venv /opt/venv

ENV PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# Setup User and Directories
RUN useradd --create-home appuser && \
    mkdir /certs

WORKDIR /home/appuser

COPY main.py .
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# Entrypoint runs as root to fix perms, then drops to appuser
ENTRYPOINT ["./entrypoint.sh"]
CMD ["python", "-u", "main.py"]
