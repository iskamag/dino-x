# Dino round 2: issue list and remediation

Branch: `round2` (based on `master` / `04cc237f`)

This round started from two user reports:

1. Sending with OMEMO enabled **stalls client-side for some contacts**, apparently
   until a contact/device-list request is fulfilled.
2. **Pre-send image previews are transparent** (the attachment thumbnails shown
   before sending).

The list below is the result of the code audit, ordered by user impact. The
status column is updated as fixes land on this branch.

Legend: **V** = reproduced/verified at runtime, **T** = code trace only.

---

## Status overview

| # | Issue | Severity | Evidence | Status |
|---|-------|----------|----------|--------|
| O1 | Failed OMEMO device-list request never unblocks pending messages | High | T | fixed |
| O2 | Empty OMEMO device list makes `is_known_address()` false forever -> request/retry loop | High | T | fixed |
| O3 | Learned devices (`insert_device_session`) never get `last_active`, so contacts learned from inbound traffic are "unknown" | High | T | fixed |
| O4 | `is_known_address()` compares the full JID while all writes use the bare JID | Medium | T | fixed |
| O5 | OMEMO IQ request caches are never cleared on stream detach and have no timeout -> one dropped IQ wedges a contact until restart | High | T | fixed |
| O6 | `Pubsub.request()` ignores the `send_iq` write failure and the listener never fires | Medium | T | fixed |
| O7 | Keyless OMEMO stanzas can be sent when the contact has no usable devices | High | T | fixed |
| O8 | Identity-key change refusal loops on refetch and has no re-verification path | Medium | T | fixed |
| O9 | `fetch_bundles()` skips a device with an existing (possibly broken) session, so the waiter is never released | Medium | T | fixed |
| O10 | `on_self_bundle_result` returns before clearing the in-flight marker if the OMEMO context is unavailable | Low | T | fixed |
| O11 | Successful empty PEP result wipes the known device list | Medium | T | fixed (guarded by O2/O7) |
| O12 | Bundle fetch failures retry with no backoff | Low | T | fixed |
| O13 | `on_device_list_loaded` early-returns without unblocking, and counters are decremented for unrelated messages | Low | T | fixed |
| O14 | `message_states` is never pruned; locking is inconsistent | Low | T | partial |
| O15 | `encryptors[account]` may be null in `on_pre_message_send` | Low | T | fixed |
| O16 | Remote crash: `int.parse` on bundle attributes and null `identity_key` dereference | High | T | fixed |
| O17 | Stale IQ callbacks / invalid device ids can mutate state after a reconnect | Low | T | fixed |
| I1 | Pre-send attachment preview uses `Gtk.Picture.file`; GTK 4.24 resolves GIF/WebP/BMP to a transparent `GtkSvg` placeholder | High | V | fixed |
| I2 | Chat input preview does not apply EXIF orientation | Low | V | fixed |
| I3 | `ImagePreview.decode_webp` passes destination offsets as source offsets to `composite()` | Medium | T | fixed |
| I4 | `ImagePreview.decode_webp` can return a null pixbuf (`apply_embedded_orientation()` without fallback) | Medium | T | fixed |
| I5 | `PreviewFileChooserNative` has the same null-orientation fallback bug | Low | T | fixed |
| I6 | `sfs_metadata` assumes a non-null preview pixbuf and a local file path | Low | T | fixed |
| I7 | Outgoing thumbnails are generated from an 8x8 preview; transparent first frames yield invisible thumbnails | Low | T | documented |
| P1 | Avoid new per-recipient DB queries / per-message scans | - | - | constraint |

"documented" means the behaviour is left as designed but the limitation is
recorded (changing it would grow every outgoing file message).

---

## O1. Failed OMEMO device-list request never unblocks pending messages

`StreamModule.request_user_devicelist()` resolves its future on `!success` but
does not emit `device_list_loaded`. `Manager.on_pre_message_send()` parks the
message in `message_states` with `waiting_other_devicelists = 1`; only
`Manager.on_device_list_loaded()` decrements it. A PEP error (no mutual
subscription, `item-not-found`, rate limiting) therefore leaves the message
unsent forever. When the contact later accepts the subscription,
`on_mutual_subscription()` fetches the list and the message finally sends.

Fix: introduce an explicit device-list result (`ok`, `empty`, `error`) and a
`device_list_fetch_failed` signal. On failure the manager keeps the message
pending and retries with exponential backoff; after the configured number of
attempts it marks the message `WONTSEND` (visible "Unable to send message") but
keeps its state so a later successful fetch can revive it.

## O2. Empty device list leaves `is_known_address()` false forever

`is_known_address()` required a `identity_meta` row with `last_active > 0`.
`insert_device_list()` writes no rows for an empty list, so a contact without
OMEMO devices is never "known": every retry requests the list again, which
succeeds empty again, which triggers another retry. The send loop issues one
PEP request per round-trip forever.

Fix: `is_known_address()` is based on the per-address `trust` row, which
`on_device_list_loaded()` creates after any successful fetch (including an
empty one), with the old `last_active > 0` check as a migration fallback.

## O3. Devices learned from incoming messages never set `last_active`

`insert_device_session()` (called from `OmemoDecryptor.update_db_for_prekey()`)
does not set `last_active`. Combined with O2 this makes contacts we have only
received OMEMO messages from permanently "unknown". Fixed by O2's new
definition; a session-learned address is still not treated as a fetched device
list, which is intentional (we do not know the contact's other devices).

## O4. Full JID vs bare JID in `is_known_address()`

All writers use `jid.bare_jid.to_string()`, the reader used `jid.to_string()`.
Conversations created from a full JID (`xmpp:user@host/resource`) never match.
Fixed by normalising to the bare JID.

## O5. No timeout / no cleanup for in-flight OMEMO requests

`active_devicelist_requests` and `active_bundle_requests` live on the
per-account `StreamModule` for the whole session. A response lost to a
disconnect leaves an unresolved future / a set entry forever: later calls
return the stuck future and `fetch_bundle()` is silently skipped. One dropped
IQ permanently breaks OMEMO for that contact.

Fix: `Pubsub.request()` gets a bounded response timeout (cancellable + timer),
pending device-list promises are failed and pending bundle requests are
signalled as failed in `StreamModule.detach()`, and both maps are cleared on
attach.

## O6. `Pubsub.request()` ignores the IQ write failure

The listener is passed to `Iq.send_iq()`, which removes the response listener
when the write fails and returns a future nobody observes. The OMEMO promise
then never resolves. Fix: use `send_iq_async()` with a cancellable; call the
listener with `success = false` on write errors/timeouts.

## O7. Keyless OMEMO stanzas

When `other_devices == 0` but own devices exist, `encrypt_key_to_recipients()`
returns before adding any `<key>` elements, yet `encrypt()` still stamps the
OMEMO node and `MessageState` did not treat `other_devices == 0` as unsafe.
The message is sent and cannot be decrypted by anyone.

Fix: treat "known address but no usable recipient devices" as `WONTSEND` and
never emit a keyless stanza.

## O8. Identity-key change refusal loops and cannot be resolved

`insert_device_bundle()` refuses the new key, the manager set trust `UNKNOWN`,
called `continue_message_sending()` and returned, so the waiter was released
and the message was immediately re-encrypted and refetched against the same
refusal. There was no way to accept the new key (see `TODO.md`).

Fix: persist the refused key in a new `pending_identity_key_public_base64`
column, do not release the message waiter, mark the message `WONTSEND`, and add
an explicit `Manager.accept_pending_identity_key()` action (old session
dropped, key replaced, trust set, bundle refetched, waiters released). The
device list UI shows the old and the new fingerprint with accept/reject
actions. Auto-accept never applies to a changed key.

## O9. Existing broken sessions are never retried

`fetch_bundles()` only fetches when `!store.contains_session(address)`. If a
session exists but `encrypt_key` fails with `UNKNOWN`, the manager waits for a
bundle that is never requested. Fix: the manager releases/refetches when the
session exists but encryption failed; see `MessageState` handling.

## O10-O15

- O10: remove the in-flight marker on every `on_self_bundle_result` path.
- O11: an empty successful PEP result still deactivates known devices. This is
  valid ("contact removed all devices") but combined with O7 no keyless message
  is sent any more; the send is surfaced as `WONTSEND` instead of silently
  disappearing.
- O12: bundle fetch failures are retried with a bounded delay instead of
  immediately.
- O13: `on_device_list_loaded` failure paths and counter handling.
- O14: states are pruned on the send / won't-send transitions. A pending state
  for a message deleted by the user can still linger until an event resolves
  it; deleting a *pending encrypted* message is not a normal code path and a
  dedicated signal hook was left out to avoid coupling OMEMO to the deletion
  service.
- O15: guard the encryptor lookup.

## O16. Bundle parsing could crash on hostile input

`Bundle.signed_pre_key_id` and `Bundle.PreKey.key_id` used `int.parse` on
remote attributes; a non-numeric value aborts. `Manager.on_bundle_fetched()`
also dereferenced `bundle.identity_key` before checking it, so a bundle without
an `identityKey` node crashed. Fixed with `int.try_parse` and an explicit null
guard (plus `fetch_bundle()` rejects device ids <= 0).

## O17. Stale callbacks after reconnect

A late PEP response from a previous stream could still run
`parse_device_list()` / `on_other_bundle_result()` and mutate the device list or
release waiters. `StreamModule` now carries a stream generation counter;
callbacks from an older generation are ignored.

---

## I1. Transparent pre-send image preview

`ChatInput.View.add_file()` creates `FixedRatioPicture { file = file }`, which
forwards to `Gtk.Picture.file`. On GTK 4.24 (glycin loader) GIF/WebP/BMP files
resolve to a `GtkSvg` placeholder with intrinsic size 200x200 that paints
nothing; PNG/JPEG resolve to `GdkMemoryTexture` and paint correctly. Verified
through the real widget under Xvfb: `snapshot().to_node()` is non-null for
PNG/JPEG and null for GIF/WebP (square and non-square alike). The sent bubble
is unaffected because it uses `ImagePreview` (gdk-pixbuf).

Fix: decode the attachment preview with `ImagePreview` (gdk-pixbuf) on a worker
thread and set a `Gdk.Texture` paintable, like the conversation view already
does. This also applies EXIF orientation (I2) and makes the preview independent
of GTK's file loader.

## I3-I6

- I3: `composite(canvas, dest_x, dest_y, dest_width, dest_height, dest_x,
  dest_y, ...)` passes the destination offsets as source offsets; use 0, 0.
- I4/I5: `apply_embedded_orientation()` is documented to return `NULL` when
  there is no orientation; use `?? pixbuf`.
- I6: guard the preview pixbuf and `file.get_path()` in `sfs_metadata`.
- I7: thumbnails stay capped at 8x8 by design; a transparent first frame keeps
  a transparent thumbnail. Documented, not changed (would grow every file
  message). Animated GIF/WebP attachments now show their first frame in the
  preview (the same still-image policy the conversation view already uses)
  instead of being blank.

---

## API and behaviour notes

- `Pubsub.OnResult` now takes a nullable `Jid?` (the requester JID is used when
  a response does not carry `from`). All in-tree callers are updated.
- `Pubsub.Module.request_timeout_seconds` defaults to 30 s; `0` disables the
  timeout. The OMEMO stream module does not change it.
- `Manager.ensure_get_keys_for_jid()` returns `KeyFetchResult`
  (`OK` / `UNSUPPORTED` / `FAILED`) so the input can distinguish "contact has
  no OMEMO devices" from "the request failed and will be retried".
- `Manager.accept_pending_identity_key()` / `reject_pending_identity_key()` are
  the public entry points used by the device list UI.
- Database version 6 adds `identity_meta.pending_identity_key_public_base64`;
  the column is added automatically by qlite for existing databases.
- `SendPolicy`, `RetryPolicy` and `MessageSendDecision` are public only so the
  plugin test target (which uses the public plugin vapi) can unit test them.

---

## Performance constraints

- No polling loops; retries are one timer per JID and only while messages are
  pending.
- `is_known_address()` keeps a single indexed query on the (small) trust table
  on the common path.
- `message_states` only contains pending messages; scans stay proportional to
  that set.
- Image previews are decoded once, off the main loop, at 64x64 (times the
  widget scale factor), and cancelled when the attachment is removed.

## Tests

- `main/tests/image_preview.vala` `/preview/presend-attachment`: adds PNG, GIF,
  WebP (`static` and `animated`), an interlaced GIF and a non-square JPEG
  (`orientation-6.jpg`) to a real `ChatInput.View` and asserts that the
  attachment preview has a decoded `Gdk.Texture` paintable with a positive
  intrinsic size and that `FixedRatioPicture.file` is not used. This fails on
  the pre-fix code (transparent `GtkSvg` placeholder).
- `plugins/omemo/tests/policy.vala`: `SendPolicy` (including the zero-recipient
  device keyless-send guard), `RetryPolicy` backoff and `DeviceListResult`.
- `xmpp-vala/tests/module_hardening.vala`:
  `pubsub_write_failure_releases_listener` and
  `pubsub_timeout_releases_listener` assert the listener is always released
  with `success = false`.
- `meson test -C build`: 7/7 targets pass (xmpp-vala, file transfers, OpenPGP
  database, OpenPGP file crypto, Crypto SRTP, OMEMO, image previews).
