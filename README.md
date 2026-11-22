# Celebrity Celebrity

The party game Celebrity for iOS: one phone per player, online rooms, three rounds
(Say Anything, One Word, Charades). Rules follow
[How to Play Celebrity](https://chriscoyier.net/2022/12/27/how-to-play-celebrity/).

Status: early development. The full design and task list are in [docs/PLAN.md](docs/PLAN.md).

## Layout

| Path | What it is |
|---|---|
| `App/` | SwiftUI app (iOS 17+) |
| `Packages/CelebrityCore` | Game model, no dependencies |
| `Packages/CelebrityBackend` | Backend client (supabase-swift) |
| `supabase/` | Database migrations and pgTAP tests |
| `project.yml` | XcodeGen spec; the `.xcodeproj` is generated, not committed |

## Requirements

- Xcode with the iOS 17 SDK or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [Supabase CLI](https://supabase.com/docs/guides/local-development) and Docker, for the database

## Build and test

```sh
xcodegen generate
xcodebuild -scheme Celebrity -destination 'platform=iOS Simulator,name=iPhone 17' build

swift test --package-path Packages/CelebrityCore
swift test --package-path Packages/CelebrityBackend

supabase start
supabase test db
```

## Contributing

Commits and pull request titles use [Conventional Commits](https://www.conventionalcommits.org/).

## Licence

The code is released under the [MIT licence](LICENSE). The app name "Celebrity Celebrity"
and the app icon are not covered by it.
