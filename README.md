# 🧅 TorChat P2P - Cross-Platform Decentralized Tor Chat

A completely peer-to-peer, serverless, encrypted messaging application built with **Flutter** and powered directly by the **Tor Network** using pure Dart.

---

## 🚀 Key Highlights & Architecture

- **100% Dart & Flutter Backend**: Avoids cumbersome C++ or Rust toolchains by launching the bundled Tor binary with Dart's `Process.start()` and communicating over TCP via `Socket.connect()` with the Tor Control Port and SOCKS5 proxy.
- **Direct Peer-to-Peer Communication**: Every device hosts its own V3 Hidden Service (`.onion`). Messages are delivered directly from device to device without centralized servers, third-party relays, or intermediary cloud storage.
- **Identity Portability & Key Export/Import**:
  - Export your raw `ED25519-V3` secret key string or JSON.
  - Export full backups containing your **Identity**, **Contacts**, and **Unlimited Chat History** (with optional AES-256 password protection).
  - Import your keys or backup file onto any new device to restore your exact `.onion` address and conversations instantly.
- **Unlimited Chats**: Add any peer by their `.onion` address.
- **Real-Time Delivery Confirmation**: Built-in HTTP/REST framing over Tor SOCKS5 providing live status updates (Sending, Delivered, Read, Failed) with one-tap retry.
- **Diagnostic Controls**: Integrated bootstrap monitor, live log stream, circuit renewal (`SIGNAL NEWNYM`), and port management.

---

## 🛠️ How It Works Under the Hood

```
[ Device A (Alice) ]                                      [ Device B (Bob) ]
      │                                                          │
  1. Creates Onion Service via Control Port                  1. Creates Onion Service via Control Port
     ADD_ONION ED25519-V3:...                                   ADD_ONION ED25519-V3:...
     -> alice.onion:80 -> 127.0.0.1:8765                         -> bob.onion:80 -> 127.0.0.1:8765
      │                                                          │
  2. Sends message to bob.onion:80                               │
     -> SOCKS5 Handshake to 127.0.0.1:9050                       │
     -> ATYP=0x03 (bob.onion), Port=80                           │
     -> Encrypted Tor Circuits ─────────────────────────────> 2. Tor forwards connection to
                                                                 PeerServer on 127.0.0.1:8765
                                                                 (Receives POST /api/v1/message)
                                                                 Updates SQLite database & UI!
```

---

## 🔑 Key Export & Device Migration

### Exporting:
1. Open **My Keys & Identity** from the top bar.
2. Click **Export Keys Only** to copy your `ED25519-V3` key string or JSON to clipboard.
3. Click **Export Full Backup** to export an encrypted or plain JSON backup file containing your Identity, Contacts, and entire Chat History.

### Importing on a New Device:
1. Install TorChat on your new device.
2. Go to **My Keys & Identity**.
3. **Import Private Key**: Paste your `ED25519-V3:...` secret key to immediately re-register your exact same `.onion` address.
4. **Restore Full Backup**: Select your `.json` backup file to restore all previous chats and contacts seamlessly.

---

## 📦 Running the Application

### Windows Desktop:
```powershell
flutter run -d windows
```

### Tests:
```powershell
flutter test
```

### Static Analysis:
```powershell
flutter analyze
```

---

## 🔒 Security & Privacy
- **End-to-End Encryption**: Provided natively by Tor Onion Services v3 (Ed25519 and Curve25519 cryptography).
- **Metadata Protection**: Neither your IP address nor your location is exposed to peers.
- **Local Vault**: SQLite database stored locally in your application documents directory with zero telemetry.
