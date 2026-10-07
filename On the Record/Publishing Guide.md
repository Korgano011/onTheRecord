# Publishing Your Copy of On the Record

This guide takes you from the source code to the app live on the App Store
under your own Apple Developer account. Recording and transcription work
out of the box; the Meetings and Agreements tabs run on iCloud (CloudKit),
which you set up for your own account in steps 3–6.

Plan on an afternoon for steps 1–7, plus Apple's review time (usually
1–3 days).

## What you need

- A Mac with the current Xcode (from the Mac App Store).
- An **active, paid Apple Developer Program membership** ($99/year,
  developer.apple.com/programs). A free "Personal Team" can't use iCloud or
  publish to the App Store.
- An iPhone for testing, signed in to iCloud.
- A web page you control for a **privacy policy** and a **support /
  contact** page (App Store Connect requires both URLs).

## 1. Sign in to Xcode with your developer account

1. Open **Xcode → Settings → Accounts**, click **+**, and sign in with the
   Apple ID that holds the membership.
2. Select the account. Your team should be listed as your name or company
   — **not** "(Personal Team)". If it still says Personal Team, the
   membership isn't active yet (check **Membership details** at
   developer.apple.com/account; a new enrollment or renewal can take up to
   48 hours).

## 2. Choose your bundle identifier

The bundle identifier is the app's permanent, unique ID. It's tied to your
team, can't be reused by anyone else, and **can't be changed after the app
is released** — a new ID means a new App Store listing.

1. Pick one in reverse-domain form, e.g. `com.yourcompany.OnTheRecord`
   (letters, numbers, hyphens and periods only).
2. Open `On the Record.xcodeproj`. In the Project navigator click the blue
   **On the Record** project icon, then under **TARGETS** select
   **On the Record**.
3. Open the **Signing & Capabilities** tab with **All** selected at the
   top.
4. Check **Automatically manage signing** and set **Team** to your paid
   team.
5. Replace the **Bundle Identifier** (it starts with `devplaceholder.`)
   with yours. Xcode registers it with Apple the first time it signs.

Optional: to show a different name under the app icon, change **Display
Name** on the **General** tab.

## 3. Add iCloud (CloudKit)

1. Still in **Signing & Capabilities**, click **+ Capability** and
   double-click **iCloud**.
2. In the iCloud section check **CloudKit**.
3. Under **Containers** click **+** and add `iCloud.<your bundle id>`
   (e.g. `iCloud.com.yourcompany.OnTheRecord`). Make sure it's checked.

The app always uses the default container, so no code changes are needed —
it follows your bundle identifier.

## 4. Turn on the iCloud features in the app

Open `Info.plist` (next to the `.xcodeproj`, not inside the
`On the Record` folder) and change:

```xml
<key>CloudKitEnabled</key>
<false/>
```

to `<true/>`. While it's false, Meetings and Agreements show a "needs
iCloud" message instead of working; this switch keeps the app from crashing
before the iCloud capability exists. Turn it on only after step 3.

## 5. Create the database by using the app once

CloudKit creates its record types the first time each kind of record is
saved, in the **Development** environment (what Xcode builds use).

1. Build and run on your iPhone (signed in to iCloud).
2. Do each of these once:
   - **Meetings:** start a meeting, record past one autosave part so it
     uploads (or join from a second phone).
   - **Agreements:** publish an agreement, post a comment on it, tap a
     verdict (Right / Wrong / Illegal), and report it.

That creates the record types `Meeting`, `MeetingAudio`, `Agreement`,
`Comment`, `Verdict`, and `Report`.

## 6. Add indexes in the CloudKit Dashboard

1. Go to **icloud.developer.apple.com**, open **CloudKit Database**, and
   pick your container. Make sure the environment says **Development**.
2. Go to **Schema → Indexes** and add:

   | Record type   | Field          | Index type |
   |---------------|----------------|------------|
   | MeetingAudio  | meetingCode    | Queryable  |
   | Agreement     | recordName     | Queryable  |
   | Agreement     | publishedAt    | Sortable   |
   | Comment       | agreement      | Queryable  |
   | Comment       | createdAt      | Sortable   |
   | Verdict       | agreement      | Queryable  |

3. Save, then relaunch the app and confirm the Agreements list, comments,
   verdict counts, and the Meetings list all load.

To check what's stored: **Records**, choose **Public Database**, pick a
record type, and click **Query Records**.

## 7. Deploy the schema to Production

The App Store version uses the **Production** environment, which starts
empty and has no record types until you deploy them.

1. In the CloudKit Dashboard, with your container open, choose **Deploy
   Schema Changes…** and confirm. This copies record types and indexes
   (not your test records) to Production.
2. Do this again any time you add a record type, field, or index.

Test data you created in Development stays there; it never shows up in
the released app.

## 8. Create the App Store Connect listing

1. Go to **appstoreconnect.apple.com → Apps → + → New App**.
2. Platform **iOS**; enter the app name (it must be unique on the App
   Store — "On the Record" may be taken, so have an alternative ready);
   choose your bundle identifier from the list; enter a SKU (any internal
   ID, e.g. `ontherecord-1`).
3. Fill in the listing: description, keywords, screenshots (6.9" iPhone
   at minimum), category (suggested: **Productivity** or **Business**),
   age rating questionnaire, **Privacy Policy URL**, and **Support URL**.

### App Privacy answers

Under **App Privacy**, declare what's collected. For this app:

- **Audio Data** — only when a recording is uploaded to a shared meeting.
  Purpose: App Functionality. Linked to the user (stored under their iCloud
  identity). Not used for tracking.
- **Other User Content** — published agreements, comments, verdicts, and
  reports. Purpose: App Functionality. Linked to the user. Not used for
  tracking.
- **Name** — the display name people type when publishing or commenting.
  Purpose: App Functionality. Linked to the user.

Recordings that aren't shared, and all transcription, stay on the phone
and are not "collected." The app has no ads, analytics, or tracking.

### Export compliance

The app uses only Apple's built-in encryption (HTTPS/iCloud). When asked,
answer that it **does not** use non-exempt encryption. To skip the question
on every upload, add `ITSAppUsesNonExemptEncryption` = **NO** to
`Info.plist`.

## 9. Archive and upload

1. In Xcode's toolbar set the run destination to **Any iOS Device
   (arm64)**.
2. Raise **Version** (e.g. 1.0) and **Build** (1, 2, 3…) on the **General**
   tab as needed — every upload needs a new build number.
3. **Product → Archive**. When the Organizer opens, select the archive and
   click **Distribute App → App Store Connect → Upload**.
4. After processing (10–30 minutes), the build appears in App Store
   Connect under **TestFlight**. Install it from TestFlight on your iPhone
   and run through the app once more — TestFlight builds use the
   **Production** database, so this is the real check that step 7 worked.

## 10. Submit for review

1. In App Store Connect open the version, choose the build under
   **Build**, and complete any remaining fields.
2. In **App Review Information**, add a contact and notes for the
   reviewer. Suggested notes:

   > Recording requires everyone present to agree (consent switch before
   > the mic turns on); a red RECORDING banner stays on screen and iOS
   > shows its mic indicator. The Agreements tab is user-generated
   > content: users accept community rules before posting, can report any
   > agreement or comment, and can hide everything from an author.
   > Reports are reviewed within 24 hours. Shared meetings and the
   > agreement repository require being signed in to iCloud on the device.

3. Click **Add for Review**, then **Submit**.

## After release: moderating reports

App Review requires that reported content is acted on, typically within
24 hours.

1. In the CloudKit Dashboard, switch to **Production**, open **Records →
   Public Database**, and query **Report**. Each report has the agreement
   reference, an optional comment ID, the reason, and the date.
2. To remove content, query the `Agreement` or `Comment` record and delete
   it. Deleting an agreement also removes its comments and verdicts.
3. Delete the Report record once handled.

For an abusive user, delete their content as above; repeated abuse can be
handled by removing everything they've created (records show the creator).

## Before you submit: known items to check

- **Privacy manifest.** The app stores settings with `UserDefaults`, which
  Apple lists as a "required reason" API. Add a privacy manifest
  (**File → New → File → App Privacy**), add
  `NSPrivacyAccessedAPICategoryUserDefaults` with reason **CA92.1**, and
  Xcode will include it in the build. Uploads without it get a warning
  email and may be rejected.
- **Platforms.** The target lists iPhone, iPad, Mac, and Apple Vision
  destinations. The Mac destination doesn't currently build. Unless you've
  tested the others, remove them under the target's **General →
  Supported Destinations** before archiving, so the release is iPhone (and
  iPad, if you've checked the layout).
- **Deleting your own posts.** People can publish but can't yet delete an
  agreement or comment they posted. Not strictly required, but reviewers
  sometimes ask for it on user-generated-content apps.
- **Recording laws.** Recording without everyone's consent is illegal in
  many places. The app enforces a consent step; your privacy policy and
  listing should say recordings are only for conversations everyone agrees
  to record.
