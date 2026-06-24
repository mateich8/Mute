# Mute — Online / Social backend design (for "see other profiles")

The profile feature ships **local-only** today: identity, stats, genres, preferences,
and achievements all live in `~/Library/Application Support/Mute/` and never leave the
Mac. Adding a real social layer (viewing other people's profiles, following, shared
stats) needs a hosted backend. This document is the plan for that, so it can be added
without reworking the app.

## Why it can't be local
"See other profiles" means the app must read data that lives on *other people's*
machines. That requires a shared, always-on service with authentication. A desktop app
has nowhere to host that itself.

## Recommended stack (lowest effort)
- **Supabase** (managed Postgres + Auth + Row-Level Security + REST/Realtime). Free tier
  is enough to start; no server to operate.
- Apple **Sign in with Apple** or Google OAuth for identity (the app already references a
  Google-photo option in the spec).
- The app talks to it over HTTPS with the user's bearer token.

## Data model (Postgres)
```
profiles        id (uuid, = auth uid), handle (unique), display_name, bio,
                avatar_url, join_date, is_private, level, xp
follows         follower_id, followee_id, created_at        (PK: both)
play_events     id, user_id, played_at, title, artist, video_id, duration_s
                -- batched upload of local history; powers public stats
top_cache       user_id, range, kind(artist|track|genre), payload jsonb, updated_at
                -- precomputed leaderboards so profile views are one read
badges          user_id, badge_id, earned_at
```
Row-Level Security: a row in `profiles`/`top_cache` is readable if
`is_private = false` OR `viewer follows owner` OR `viewer = owner`.

## Sync model
- **Write**: the client batches new `PlayEvent`s (we already store these locally with
  `duration`) and `POST`s them every N minutes / on quit. Server recomputes `top_cache`
  + `level`/`xp` + badges (same formulas as `Gamification` / `StatsEngine` in
  `Profile.swift` — port them to a Postgres function or an edge function so client and
  server agree).
- **Read**: `GET /profile/{handle}` → identity + `top_cache` + badges, gated by RLS.
- **Search**: `GET /profiles?q=` for finding people.

## App-side work (when we build it)
1. `AuthService` (sign-in, token storage in Keychain).
2. `SyncService` (upload local `history` deltas; respects `isPrivate`).
3. `RemoteProfile` model + a read-only `PublicProfileView` (reuse `ProfileView`'s
   subviews — they're already split into sections).
4. A "Find people" search + follow button.
5. Settings: account, sign out, "what others can see" controls.

## Privacy
- `is_private` already exists locally; it must be enforced **server-side** via RLS, not
  just hidden in the UI.
- Upload only what's needed for public stats; never upload file paths from the user's
  disk (strip to title/artist/videoId/duration — `PlayEvent` already fits this).
- Make stat-sharing opt-in.

## Mapping to the current code
- `UserProfile` (Profile.swift) ⇄ `profiles` row.
- `PlayEvent` (Models.swift, now carries `duration`) ⇄ `play_events` row.
- `StatsEngine` / `Gamification` formulas ⇄ server recompute (keep them identical).
- `GenreService` genre inference can run client-side and upload the result, or move to
  the server.
