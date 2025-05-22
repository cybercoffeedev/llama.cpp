ARG UBUNTU_VERSION=24.04
FROM ubuntu:$UBUNTU_VERSION AS build

# If you have an ARM64 CPU, set your architecture here, otherwise ignore that
ARG GGML_CPU_ARM_ARCH=armv8-a
ARG TARGETARCH

RUN apt-get update && \
    apt-get install -y clang git cmake libcurl4-openssl-dev pkg-config xz-utils

WORKDIR /app
COPY . .

RUN if [ "$TARGETARCH" = "amd64" ]; then \
        cmake -S . -B build \
            -DCMAKE_BUILD_TYPE=Release \
            -DGGML_NATIVE=OFF \
            -DLLAMA_BUILD_TESTS=OFF \
            -DGGML_BACKEND_DL=ON \
            -DGGML_CPU_ALL_VARIANTS=ON \
            -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
        cmake -S . -B build \
            -DCMAKE_BUILD_TYPE=Release \ 
            -DGGML_NATIVE=OFF \
            -DLLAMA_BUILD_TESTS=OFF \
            -DGGML_CPU_ARM_ARCH=${GGML_CPU_ARM_ARCH} \
            -DGGML_CPU_KLEIDIAI=ON \
            -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++; \
    else \
        echo "Unsupported architecture"; \
        exit 1; \
    fi && \
    cmake --build build --config Release -j $(nproc)

RUN mkdir -p /app/lib && \
    find build -name "*.so" -exec cp {} /app/lib \;

RUN mkdir -p /app/full \
    && cp build/bin/* /app/full \
    && cp *.py /app/full \
    && cp -r gguf-py /app/full \
    && cp -r requirements /app/full \
    && cp requirements.txt /app/full \
    && cp .devops/tools.sh /app/full/tools.sh

## Base image
FROM ubuntu:$UBUNTU_VERSION AS base

RUN apt-get update \
    && apt-get install -y libgomp1 curl \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

COPY --from=build /app/lib/ /app

### Full
FROM base AS full

COPY --from=build /app/full /app
WORKDIR /app

RUN apt-get update \
    && apt-get install -y \
    git \
    python3 \
    python3-pip \
    python3-venv \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --upgrade pip setuptools wheel \
    && pip install -r requirements.txt

ENTRYPOINT ["/app/tools.sh"]

### Light, CLI only
FROM base AS light

COPY --from=build /app/full/llama-cli /app
WORKDIR /app

ENTRYPOINT [ "/app/llama-cli" ]

### Server, Server only
FROM base AS server

ENV LLAMA_ARG_HOST=0.0.0.0

COPY --from=build /app/full/llama-server /app
WORKDIR /app

HEALTHCHECK CMD [ "curl", "-f", "http://localhost:8080/health" ]
ENTRYPOINT [ "/app/llama-server" ]
