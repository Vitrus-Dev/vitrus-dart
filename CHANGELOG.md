## 0.1.0

- First release: `screen`, `track`, `identify` (hashed on device), `plan`, `revenue`, `appOpen`, `flush`.
- Offline queue with batches of up to 50 to `/api/batch`; honest event ages from the monotonic clock.
- A random visitor value regenerated every UTC day — no persistent device identifier.
- Personal properties (email, phone, name, address, password, token, IP, …) dropped on device.
- `MemoryStorage`, `FileStorage`, or your own `VitrusStorage`.
