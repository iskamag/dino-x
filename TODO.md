# TODO

## OMEMO identity-key change re-verification

`plugins/omemo/src/logic/manager.vala` refuses a changed identity key but leaves
the device row active with trust `UNKNOWN`. The old key is retained, so
`insert_device_bundle()` keeps refusing and the message stays `UNSAFE`/stuck.

Needed:

- Persist the refused key separately (for example
  `pending_identity_key_public_base64`) instead of discarding it.
- Surface the key change in the device/trust UI, showing both the known and the
  new fingerprint.
- Add an explicit accept action that replaces the identity key, resets the
  stored OMEMO session, and re-fetches the bundle before starting a new session.
- Keep the current safe default: never accept a changed key without user action.
- Add a regression test covering refusal, explicit acceptance and message
  recovery.
