#!/bin/bash

./configure                                                                   \
    --with-debug                                                              \
    --with-cc-opt='-g -O0'                                                    \
    --with-threads                                                            \
    --with-http_ssl_module                                                    \
    --with-http_v2_module                                                     \
    --with-http_slice_module                                                  \
    --with-http_realip_module                                                 \
    --with-stream_realip_module                                               \
    --with-http_gzip_static_module                                            \
    --with-http_auth_request_module                                           \
    --with-http_secure_link_module                                            \
    --with-http_stub_status_module                                            \
    --with-stream                                                             \
    --with-stream_realip_module                                               \
    --add-module=./3rd/lua-nginx-module                                       \
    --add-module=./3rd/njs/nginx                                              \
    --with-pcre=/Users/balus/Desktop/Workspace/iInstall/pcre-8.44             \
    --with-pcre-jit                                                           \
    --with-openssl=/Users/balus/Desktop/Workspace/iInstall/openssl-1.1.1n

    #--with-pcre=/Users/balus/Desktop/Workspace/iInstall/pcre2-10.39           \

if [ $? -eq 0 ]; then
  echo "CONFIGURE SUCCEEDED!"
  # make -j16 && sudo make install
fi
