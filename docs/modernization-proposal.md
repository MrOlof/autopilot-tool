# Autopilot Tool - Modernization Proposal

## Problem Statement

The current architecture uses a static Azure Function key embedded on the USB as the sole authentication mechanism. While the Function App proxy pattern is solid (no Graph credentials on the USB), this approach has gaps:

- **No user identity** tied to registrations - can't answer "who registered this device?"
- **No central audit trail** - the USB is the source of truth; if it's lost, history is gone
- **Static key at rest** - a stolen USB grants indefinite access to the upload endpoint
- **No rate limiting** - a compromised key allows unlimited hash submissions
- **No approval workflow** - every submitted hash gets registered automatically

---

## Proposed Architecture: QR Code + Entra ID Session Flow

Replace the static function key with a short-lived, user-authenticated session.

### Flow

```
  OOBE Device (Shift+F10)                Technician's Phone
  ========================                ====================

  1. Run AutopilotTool.ps1
  2. POST /api/session
     -> returns sessionId + QR URL
  3. Display QR code on screen  -------->  4. Scan QR code
                                           5. Browser opens approval page
                                           6. Sign in with Entra ID
                                           7. Approve session
  8. Poll GET /api/session/{id}/status
     -> status changes to "approved"
     -> receives short-lived token
  9. POST /api/upload (with session token)
  10. Registration complete
```

### Why This Is Better

| Aspect | Current | Proposed |
|--------|---------|----------|
| USB contents | Script + function key + branding | Script + function URL only (no secrets) |
| Authentication | Static function key | Entra ID via phone + session token |
| Identity | Anonymous | Every registration tied to a user (UPN) |
| Key lifetime | Indefinite (until manually rotated) | 15-minute single-use session token |
| Stolen USB risk | Attacker can upload hashes | Useless without an authorized Entra account |
| Authorization | Anyone with the key | Scoped to an Entra security group |

### New Endpoints

Add to the existing Azure Function App:

#### `POST /api/session`

Creates a pending session. No authentication required (this is what the USB calls).

**Response:**
```json
{
  "sessionId": "a1b2c3d4-...",
  "qrUrl": "https://autopilot.contoso.com/approve?session=a1b2c3d4-...",
  "expiresAt": "2026-04-07T14:15:00Z"
}
```

#### `GET /api/session/{id}/status`

Polled by the USB tool. Returns `pending`, `approved`, or `expired`.

When approved, includes a short-lived session token:
```json
{
  "status": "approved",
  "token": "eyJ...",
  "approvedBy": "tech@contoso.com"
}
```

#### `POST /api/upload` (modified)

Now requires a valid session token in the `Authorization` header instead of a function key.

The function validates the token, extracts the user identity, and includes it in the audit record.

### Approval Page

A lightweight static page (Azure Static Web App or hosted on the Function App):

- Uses `@azure/msal-browser` for Entra ID sign-in
- Checks membership in an `AutopilotRegistrators` security group
- Displays the session details (device serial, manufacturer, model if available)
- Single "Approve" button that calls a backend endpoint to mark the session as approved
- Could optionally show group tag selection here instead of on the OOBE device

### Session Storage

Use Azure Table Storage (the Storage Account already exists in the Bicep template):

**Table: `sessions`**

| PartitionKey | RowKey | Status | CreatedAt | ExpiresAt | ApprovedBy | DeviceSerial | Token |
|---|---|---|---|---|---|---|---|
| 2026-04-07 | {sessionId} | approved | ... | ... | tech@contoso.com | ABC123 | eyJ... |

TTL enforcement: the `/api/session/{id}/status` endpoint checks `ExpiresAt` and returns `expired` if past. A timer-triggered function can clean up old rows daily.

---

## Central Audit Log

Every registration should be recorded in Table Storage, not just in Application Insights.

**Table: `registrations`**

| PartitionKey | RowKey | SerialNumber | GroupTag | RegisteredBy | ClientIP | GraphImportId | Status | Timestamp |
|---|---|---|---|---|---|---|---|---|
| 2026-04 | {guid} | ABC123 | IT-Standard | tech@contoso.com | 10.0.0.5 | {importId} | Complete | 2026-04-07T10:30:00Z |

### Structured Logging

Wire Application Insights with structured telemetry in every endpoint:

```powershell
$telemetry = @{
    Event      = "DeviceRegistration"
    Serial     = $serialNumber
    GroupTag   = $groupTag
    User       = $approvedBy
    ClientIP   = $clientIp
    ImportId   = $importId
    Status     = "Success"
}
Write-Host ("AUDIT | " + ($telemetry.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join " | ")
```

This makes logs queryable in Log Analytics:

```kusto
traces
| where message startswith "AUDIT"
| parse message with "AUDIT | Event=" event " | Serial=" serial " | User=" user *
| summarize count() by user, bin(timestamp, 1d)
```

---

## Security Hardening

### Entra Security Group Gating

The approval page checks group membership before allowing session approval:

```
AutopilotRegistrators (Entra Security Group)
  -> tech1@contoso.com
  -> tech2@contoso.com
  -> fieldops@contoso.com
```

Only members can approve sessions. Managed centrally in Entra ID.

### Rate Limiting

Options (pick one):

1. **Azure API Management (Consumption tier)** - add `rate-limit-by-key` policy (e.g., 10 sessions/hour per IP)
2. **Function-level counter** - track session creation per IP in Table Storage, reject above threshold
3. **Azure Front Door** - WAF rules with rate limiting

### Session Security

- 15-minute TTL, enforced server-side
- Single-use: token invalidated after first successful upload
- Token is a signed JWT (HS256 with a Function App setting as the secret), containing sessionId + UPN + expiry
- Sessions cannot be re-approved once expired

### Duplicate Prevention

Check serial number in the `registrations` table before calling Graph. Faster than waiting for a Graph 409 response and gives better error messages.

---

## Optional Enhancements

### Admin Dashboard

A Static Web App with Entra authentication showing:

- Registration history (searchable, filterable)
- Pending sessions
- Daily/weekly registration metrics
- Failed registration alerts

Tech options: React + SWA + read-only Function endpoints, or a Power BI report over Table Storage.

### Teams/Slack Notifications

Trigger a Logic App or Power Automate flow on registration events:

```
New device registered
  Serial: ABC123
  Group Tag: IT-Standard
  Registered by: tech@contoso.com
  Status: Complete
```

### Offline Queue

For sites with unreliable OOBE network:

- Tool saves hardware hash as a signed JSON file on the USB
- Technician bulk-uploads later via the admin dashboard
- Each file is signed with a device-specific nonce from a pre-authenticated session

### Device Naming Convention

Let the approval page enforce a naming template based on group tag and serial:

```
{GroupTag}-{SerialLast6}  ->  IT-STD-X1C123
```

---

## Implementation Priority

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| 1 | QR + Entra session flow | Medium | Eliminates static key, adds identity |
| 2 | Table Storage audit log | Low | Central source of truth for all registrations |
| 3 | Structured App Insights logging | Low | Queryable telemetry |
| 4 | Security group gating | Low | Authorization control |
| 5 | Rate limiting | Low-Medium | Abuse prevention |
| 6 | Admin dashboard | Medium | Visibility for IT admins |
| 7 | Teams notifications | Low | Real-time awareness |
| 8 | Offline queue | Medium | Edge case resilience |

---

## Migration Path

This can be implemented incrementally alongside the existing function key flow:

1. **Phase 1**: Add session endpoints + approval page + Table Storage. Keep existing function key auth as fallback.
2. **Phase 2**: Update the field tool to use QR flow by default, function key as optional flag (`-UseLegacyAuth`).
3. **Phase 3**: Remove function key support. All registrations require QR + Entra auth.

Existing USBs continue to work during Phase 1 and 2. No big-bang cutover required.
