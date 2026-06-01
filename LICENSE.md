# License

This repository, **spangap** (the platform meta-repo: build-environment image,
host-side shim, in-container CLI, and manifest schemas), is released under the
**Apache License, Version 2.0**.

Full license text: <https://www.apache.org/licenses/LICENSE-2.0>

Copyright (c) 2026 by spangap project contributors.

> Licensed under the Apache License, Version 2.0 (the "License");
> you may not use this file except in compliance with the License.
> You may obtain a copy of the License at
>
>     http://www.apache.org/licenses/LICENSE-2.0
>
> Unless required by applicable law or agreed to in writing, software
> distributed under the License is distributed on an "AS IS" BASIS,
> WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

## Third-party software

### Vendored in this repository

None. This repo contains no third-party source code.

### Build-time dependencies

The Docker build-env image (see `Dockerfile`) layers third-party software on
top of `espressif/idf:v5.5.4`. That base image and the packages installed into
it (Node 20, Python, Cairo, Pillow, Alpine/Debian system packages) retain
their own licenses; see the upstream image and package manifests for details.
None of that software is redistributed *from* this repository — the image is
built from source at install time.
