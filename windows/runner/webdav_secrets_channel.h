#ifndef RUNNER_WEBDAV_SECRETS_CHANNEL_H_
#define RUNNER_WEBDAV_SECRETS_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// 通用 DPAPI 通道：protect/unprotect 收发 Uint8List。
// Invalid arguments use bad_args; DPAPI failures use protect_failed or
// unprotect_failed with generic messages and no error details.
//
// 目前注册两份：
//   · yingshi/webdav_secrets —— WebDAV 连接记录（历史名称，勿改）；
//   · yingshi/secrets        —— 网盘账号等其它本机凭据。
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterSecretsChannel(flutter::BinaryMessenger* messenger, const char* name);

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterWebDavSecretsChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_WEBDAV_SECRETS_CHANNEL_H_
