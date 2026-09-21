// JNI bridge that runs the embedded Node.js (nodejs-mobile) in this process.
//
// NodeRuntime.startNode(argv, env) hands over the command line and extra
// environment variables; node::Start blocks on the calling thread until the
// runtime exits, so the Java side calls it from a dedicated thread. Node's
// stdout and stderr are piped into logcat under the TerraformingMars tag.
#include <jni.h>
#include <android/log.h>
#include <pthread.h>
#include <unistd.h>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "node.h"

namespace {

const char *LOG_TAG = "TerraformingMars";

struct Redirect {
  int fds[2];
  android_LogPriority priority;
};

Redirect redirectStdout{{-1, -1}, ANDROID_LOG_INFO};
Redirect redirectStderr{{-1, -1}, ANDROID_LOG_ERROR};

void *pumpToLogcat(void *arg) {
  auto *redirect = static_cast<Redirect *>(arg);
  char buffer[4096];
  ssize_t size;
  while ((size = read(redirect->fds[0], buffer, sizeof buffer - 1)) > 0) {
    if (buffer[size - 1] == '\n') {
      --size;
    }
    buffer[size] = '\0';
    __android_log_write(redirect->priority, LOG_TAG, buffer);
  }
  return nullptr;
}

bool redirectToLogcat(Redirect &redirect, FILE *stream, int fd) {
  setvbuf(stream, nullptr, _IONBF, 0);
  if (pipe(redirect.fds) != 0) {
    return false;
  }
  dup2(redirect.fds[1], fd);
  pthread_t thread;
  if (pthread_create(&thread, nullptr, pumpToLogcat, &redirect) != 0) {
    return false;
  }
  pthread_detach(thread);
  return true;
}

std::vector<std::string> toStrings(JNIEnv *env, jobjectArray array) {
  std::vector<std::string> result;
  const jsize count = env->GetArrayLength(array);
  for (jsize i = 0; i < count; i++) {
    auto element = static_cast<jstring>(env->GetObjectArrayElement(array, i));
    const char *chars = env->GetStringUTFChars(element, nullptr);
    result.emplace_back(chars);
    env->ReleaseStringUTFChars(element, chars);
    env->DeleteLocalRef(element);
  }
  return result;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_it_zerko_terraformingmars_NodeRuntime_startNode(JNIEnv *env, jclass, jobjectArray jargv, jobjectArray jenv) {
  for (const std::string &assignment : toStrings(env, jenv)) {
    const size_t equals = assignment.find('=');
    if (equals != std::string::npos) {
      setenv(assignment.substr(0, equals).c_str(), assignment.substr(equals + 1).c_str(), 1);
    }
  }

  // libuv wants argv laid out in one contiguous block of memory.
  const std::vector<std::string> arguments = toStrings(env, jargv);
  size_t total = 0;
  for (const std::string &argument : arguments) {
    total += argument.size() + 1;
  }
  char *block = static_cast<char *>(calloc(total, sizeof(char)));
  std::vector<char *> argv;
  char *cursor = block;
  for (const std::string &argument : arguments) {
    memcpy(cursor, argument.c_str(), argument.size() + 1);
    argv.push_back(cursor);
    cursor += argument.size() + 1;
  }

  if (!redirectToLogcat(redirectStdout, stdout, STDOUT_FILENO) ||
      !redirectToLogcat(redirectStderr, stderr, STDERR_FILENO)) {
    __android_log_write(ANDROID_LOG_WARN, LOG_TAG, "Could not redirect Node output to logcat");
  }

  return static_cast<jint>(node::Start(static_cast<int>(argv.size()), argv.data()));
}
