/* A stand-in for the native varlatch CLI (0.50 and later), for tests/run.sh,
 * which builds it: VERSION is the release it is from. Calls other than
 * --version are recorded in $HOME/calls.log.
 *   REPORTS          the version it reports, when it is not VERSION
 *   BAD_SIGNATURE    verify-release fails
 *   BREAKS_IN_PLACE  runs as downloaded, but not once installed
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef REPORTS
#define REPORTS VERSION
#endif

int main(int argc, char **argv) {
  const char *command = argc > 1 ? argv[1] : "";
#ifdef BREAKS_IN_PLACE
  {
    const char *base = strrchr(argv[0], '/');
    base = base ? base + 1 : argv[0];
    if (!strcmp(base, "varlatch")) return 126;
  }
#endif
#ifdef BREAKS_WHEN_STAGED
  if (strstr(argv[0], ".varlatch-new.")) return 126;
#endif
  if (!strcmp(command, "--version")) {
    puts("varlatch " REPORTS);
    return 0;
  }
  char path[4096];
  snprintf(path, sizeof path, "%s/calls.log", getenv("HOME"));
  FILE *log = fopen(path, "a");
  if (log) {
    fputs("native", log);
    for (int i = 1; i < argc; i++) fprintf(log, " %s", argv[i]);
    fputc('\n', log);
    fclose(log);
  }
  if (!strcmp(command, "verify-release")) {
#ifdef BAD_SIGNATURE
    fputs("varlatch verify-release: not signed\n", stderr);
    return 1;
#else
    puts("signed");
    return 0;
#endif
  }
  if (!strcmp(command, "status")) puts("{\"version\":1,\"servers\":[],\"repo\":null}");
  return 0;
}
