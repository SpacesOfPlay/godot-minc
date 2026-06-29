# License — godot-minc

The minc-language bindings and example extensions in this repository (`lib/`,
`examples/`, `bindgen/`, and the build/tooling scripts) are released under the
MIT License, below.

> **The minc compiler is NOT covered by the license below.** This repo ships
> only minc-language source. Building it requires the `minc` compiler from
> <https://github.com/SpacesOfPlay/minc-dev/releases>, which is closed-source
> proprietary software. The optional helper `tools/get_minc.ps1` /
> `tools/get_minc.sh` downloads that binary on demand into `tools/minc/`
> (gitignored). The terms governing your use of `minc.exe` / `minc` are stated
> in the `LICENSE.md` shipped inside that minc release (`tools/minc/LICENSE.md`
> after running the fetcher).

> **Godot is separately licensed.** The Godot engine is MIT-licensed by the
> Godot Engine contributors (<https://godotengine.org/license>). This repo does
> not redistribute Godot; `tools/get_godot.ps1` / `tools/get_godot.sh` download
> an official release on demand into `tools/godot/` (gitignored). The bindings
> in `lib/godot_classes.mc` / `godot_enums.mc` / `godot_utility.mc` are
> generated from Godot's public `extension_api.json` (vendored in `bindgen/`).

---

MIT License

Copyright (c) 2026 Mattias Ljungström, Spaces of Play UG (haftungsbeschränkt)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
