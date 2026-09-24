# Releasing

Every file that has to change for a release, in the order they have to change,
because the ones that are easy to forget are the ones nothing checks. Nothing
in CI catches a README still describing the previous version's dependency.

## Before

- [ ] `CHANGELOG.md`: move `Unreleased` into a new version heading, dated, and
      add the compare links at the bottom.
- [ ] `src/nerves_hub_link_atomvm_esp32.app.src`: bump `vsn`.
- [ ] `README.md`: the version in the **Installing** snippet, if the major or
      minor moved. This is the one that gets missed.
- [ ] `rebar3 eunit`, `rebar3 dialyzer`, `rebar3 xref`, `rebar3 fmt --check`.
- [ ] Build a throwaway project that depends only on this package and check the
      install snippet against it. Nothing else catches a snippet that lists a
      dependency rebar3 would have resolved anyway, or plugins leaking into a
      consumer's build.
- [ ] `rebar3 hex build`, then unpack the tarball and look at what is in it.
      `files` in the app.src is an allow list, so a new top-level directory is
      absent until someone adds it.

## Publish

```
rebar3 hex publish
```

Hex allows an hour to revert a publish and nothing after that, so read what it
prints before confirming.

## After

```
git tag -a v0.2.0 -m "v0.2.0"
git push origin v0.2.0
```

Then, if the minor moved, the Elixir package's dependency on this one needs
the same bump. It lives in its own repository and nothing here will remind you.

## What does not change

`atomvm_websocket_client` stays a git dependency in the Installing snippet. It
is not on Hex and is not going to be: it is an ESP-IDF component first, and the
half that matters is compiled into the VM rather than fetched by rebar3.

The examples use `path` and git dependencies deliberately. An example inside
this repository should build against the code it ships with, not against the
last published version of it.
