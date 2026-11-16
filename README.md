# network-connection-state-counter

Counts TCP sockets in each state by parsing `/proc/net/tcp`.

```bash
source ./network_connection_state_counter.sh

# Live system table.
ncs_count_default
# => ESTABLISHED 12
#    LISTEN 4
#    TIME_WAIT 37

# Or point it at a captured snapshot.
ncs_count_file /tmp/tcp.snapshot

# Translate a single raw state code.
ncs_state_name 06
# => TIME_WAIT
```

## Why this exists

`ss` and `netstat` are great for looking at sockets, but they are not always
available in minimal containers, and their output formats differ between
distributions. `/proc/net/tcp` is always present on Linux and has a stable
column layout, so it is a reliable source for a small counter. The trade-off
is that we only read the IPv4 table. The IPv6 table has the same state field
but a wider address field, and since we only care about the state column we
could read it too — we choose not to, because a caller who wants both can
call the counter twice and sum the results, whereas a caller who wants IPv4
only cannot easily subtract IPv6 out of a combined result.

## API

All functions are plain shell functions; source the script to use them.

- `ncs_state_name CODE` — print the conventional name for a two-hex-digit
  TCP state code. Unknown codes print as `UNKNOWN_<CODE>` (uppercased) so a
  new kernel state is visible rather than silently dropped.
- `ncs_count_file PATH` — read a `/proc/net/tcp`-style file and print one
  line per state, `NAME COUNT`, sorted by name. Returns status 1 if the file
  cannot be read, status 2 if the path argument is empty.
- `ncs_count_default` — call `ncs_count_file /proc/net/tcp`.

## Edge cases

The state field is a hex code, and the kernel does not guarantee a trailing
newline on the last line of `/proc/net/tcp`. The reader loop is written so
that a final line without a newline is still counted; a naive `while read`
would drop it. The header line is skipped by matching the literal string
`local_address`, which is stable across kernels we have seen. Empty paths
and unreadable files are reported on stderr and distinguished by exit
status, so a caller can tell a missing snapshot from a malformed one.
