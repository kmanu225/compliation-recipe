#!/bin/bash
set -e

WORKING_DIR="$(pwd)/curl_arm_build"
INSTALL_DIR="$WORKING_DIR/output"
CROSS_COMPILE_URL="https://musl.cc/armv7l-linux-musleabihf-cross.tgz"
ZLIB_VERSION="1.3.2"
OPENSSL_VERSION="1.0.2f"
CURL_VERSION="8.6.0"

mkdir -p "$WORKING_DIR" "$INSTALL_DIR"
cd "$WORKING_DIR"

echo "--- 1. Toolchain Setup ---"
# Download & extract musl-based toolchain
if [ ! -d "armv7l-linux-musleabihf-cross" ]; then
    wget -c "$CROSS_COMPILE_URL"
    tar xzf armv7l-linux-musleabihf-cross.tgz
fi

# Set environment variables
export PATH="$WORKING_DIR/armv7l-linux-musleabihf-cross/bin:$PATH"
CROSS_HOST="armv7l-linux-musleabihf"
CROSS_PREFIX="${CROSS_HOST}-"

echo "--- 2. Build Zlib (Static) ---"
if [ ! -d "zlib-$ZLIB_VERSION" ]; then
    wget -c "https://zlib.net/zlib-$ZLIB_VERSION.tar.gz"
    tar xzf "zlib-$ZLIB_VERSION.tar.gz"
fi
cd "zlib-$ZLIB_VERSION"
# Force static build
# -j$(nproc) is used to parallelize operation on all the available CPU cores
CHOST=$CROSS_HOST CC=${CROSS_PREFIX}gcc ./configure --static --prefix="$INSTALL_DIR"
make -j$(nproc) && make install
cd ..

echo "--- 3. Build OpenSSL (Legacy version) ---"
if [ ! -d "openssl-$OPENSSL_VERSION" ]; then
    wget -c "https://github.com/openssl/openssl/releases/download/OpenSSL_1_0_2f/openssl-$OPENSSL_VERSION.tar.gz"
    tar xzf "openssl-$OPENSSL_VERSION.tar.gz"
fi

cd "openssl-$OPENSSL_VERSION"
# Configure for ARM with no shared libraries
./Configure linux-armv4 -static --cross-compile-prefix=$CROSS_PREFIX --prefix="$INSTALL_DIR" --openssldir="$INSTALL_DIR" no-shared no-tests
make -j$(nproc)
make install_sw # install_sw avoid installing man pages
cd ..

echo "--- 4. Build cURL (The Final Boss) ---"
if [ ! -d "curl-$CURL_VERSION" ]; then
    wget -c "https://curl.se/download/curl-$CURL_VERSION.tar.gz"
    tar xzf "curl-$CURL_VERSION.tar.gz"
fi
cd "curl-$CURL_VERSION"
make distclean || true

# Linking everything together
./configure --host=$CROSS_HOST \
            --prefix="$INSTALL_DIR" \
            --with-openssl="$INSTALL_DIR" \
            --with-zlib="$INSTALL_DIR" \
            --enable-static \
            --disable-shared \
            --disable-ldap \
            --without-libpsl \
            --disable-threaded-resolver \
            CC="${CROSS_PREFIX}gcc" \
            AR="${CROSS_PREFIX}ar" \
            RANLIB="${CROSS_PREFIX}ranlib" \
            CPPFLAGS="-I$INSTALL_DIR/include" \
            LDFLAGS="-L$INSTALL_DIR/lib" \
            LIBS="-lssl -lcrypto -lz -lpthread -ldl"

# Force 100% static linking
make -j$(nproc) LDFLAGS="-static -all-static -L$INSTALL_DIR/lib"
make install

echo "--- VERIFICATION ---"
# Remove debug symbols to reduce size
${CROSS_PREFIX}strip "$INSTALL_DIR/bin/curl"
file "$INSTALL_DIR/bin/curl"
# Ensure no dynamic dependencies remain
${CROSS_PREFIX}readelf -d "$INSTALL_DIR/bin/curl" | grep "NEEDED" || echo "SUCCESS: 100% Static Binary!"

echo "--- QEMU TEST ---"
qemu-arm-static "$INSTALL_DIR/bin/curl" --version