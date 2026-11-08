defines({ 'WITH_RIVE_AUDIO_TOOLS', 'RIVE_NO_CORETEXT', 'MICROPROFILE_WEBSERVER=0' })
filter({ 'options:arch=wasm', 'options:not single-threaded' })
do
    buildoptions({ '-pthread' })
    linkoptions({
        '-pthread',
        '-sPTHREAD_POOL_SIZE=20',
        '--post-js ' .. path.getabsolute('./platform/wasm/scripting_work_callbacks.js'),
    })
end
filter({})
dofile('rive_build_config.lua')

-- Which scripting backend librive carries: luau (default), wasm, or both.
-- On the web the wasm backend runs modules on the browser's engine, so WAMR
-- and what needs a desktop (withWasmVm) stay out while the bindings stay in.
local scriptingVm = _OPTIONS['scripting_vm'] or 'luau'
local withWasmBackend = scriptingVm == 'wasm' or scriptingVm == 'both'
local withWasmVm = withWasmBackend and _OPTIONS['arch'] ~= 'wasm'

-- Detect where packages path is.
if os.isfile('../../runtime/premake5_v2.lua') then
    packages = '../..'
elseif os.isfile('../runtime/premake5_v2.lua') then
    packages = '..'
else
    error('Could not find packages folder.')
end

if not _OPTIONS['no-rive-decoders'] then
    dofile(packages .. '/runtime/decoders/premake5_v2.lua')
end
dofile(packages .. '/runtime/premake5_v2.lua')
dofile(packages .. '/runtime/renderer/premake5_pls_renderer.lua')

if not _OPTIONS['flutter_runtime'] then
    -- Edit-time boolean path operations (editor-only; never shipped in the
    -- flutter runtime).
    dofile(packages .. '/pathops/premake5.lua')
    -- Markup conversion behind the editor's .rml export (editor-only too).
    dofile(packages .. '/rml/premake5_rml.lua')
else
    -- Dummy so the podspec's unconditional -lrive_pathops link resolves in
    -- flutter_runtime builds (same pattern as luau/spirv_cross/rust_ffi).
    project('rive_pathops')
    do
        kind('StaticLib')
        files({ 'dummy.cpp' })
    end
    project('rml')
    do
        kind('StaticLib')
        files({ 'dummy.cpp' })
    end
    project('rive_codec')
    do
        kind('StaticLib')
        files({ 'dummy.cpp' })
    end
end

if not _OPTIONS['flutter_runtime'] then
    -- The AnimaScript bake and the std it compiles against, whatever VM
    -- runs scripts, since every tools build exports AnimaScript. binaryen's
    -- post pass stays native; the web keeps rasc's own optimizer.
    RIVE_RASC_WASM = true
    RIVE_RASC_BUNDLE_STD = true
    RIVE_RASC_NO_BINARYEN = _OPTIONS['arch'] == 'wasm'
    local scripting =
        require(path.getabsolute(packages) .. '/scripting_workspace/premake5_scripting_workspace')
    luau = scripting.luau
    brotli = scripting.brotli
else
    luau = ''
    brotli = ''
    -- dummies
    project('rive_scripting_workspace')
    do
        kind('StaticLib')
        files({ 'dummy.cpp' })
    end
    project('rasc_front')
    do
        kind('StaticLib')
        files({ 'dummy.cpp' })
    end
    project('spirv_cross')
    do
        kind('StaticLib')
        files({ 'dummy.cpp' })
    end
    project('brotli')
    do
        kind('StaticLib')
        files({ 'dummy.cpp' })
    end
    project('luau_vm')
    do
        kind('StaticLib')
        files({ 'dummy.cpp' })
    end
    project('rust_ffi')
    do
        kind('StaticLib')
        files({ 'dummy.cpp' })
    end
    project('luau_compiler')
    files({ 'dummy.cpp' })
    do
        kind('StaticLib')
        files({ 'dummy.cpp' })
    end
    project('luau_analyzer')
    do
        kind('StaticLib')
        files({ 'dummy.cpp' })
    end
    project('spirv_cross')
    do
        kind('StaticLib')
        files({ 'dummy.cpp' })
    end
end

project('rive_native')
do
    if _OPTIONS['arch'] ~= 'wasm' then
        if _OPTIONS['shared'] then
            kind('SharedLib')
            links({
                'rive',
                'rive_harfbuzz',
                'rive_sheenbidi',
                'rive_yoga',
                'rive_pls_renderer',
                'rive_decoders',
                'libwebp',
                'luau_vm',
                'luau_compiler',
                'miniaudio',
                'brotli',
            })
            if withWasmVm then
                links({ 'wamr' })
            end
            if RIVE_RASC_WASM and not RIVE_RASC_NO_BINARYEN then
                -- The bake's post pass runs binaryen in process.
                links({ 'binaryen' })
            end
            filter({ 'options:not no_rive_png' })
            do
                links({ 'zlib', 'libpng' })
            end
            filter({ 'options:not no_rive_jpeg' })
            do
                links({ 'libjpeg' })
            end
            filter({ 'options:not flutter_runtime', 'options:arch=arm64', 'system:macosx' })
            do
                libdirs({
                    '../../scripting_workspace/target/aarch64-apple-darwin/minimize/',
                })
            end
            filter({ 'options:not flutter_runtime', 'options:arch=x64', 'system:macosx' })
            do
                libdirs({
                    '../../scripting_workspace/target/x86_64-apple-darwin/minimize/',
                })
            end
            filter({ 'options:not flutter_runtime', 'options:arch=x64', 'system:linux' })
            do
                libdirs({
                    '../../scripting_workspace/target/x86_64-unknown-linux-gnu/minimize/',
                })
            end
            filter({ 'options:not flutter_runtime', 'options:arch=arm64', 'system:linux' })
            do
                libdirs({
                    '../../scripting_workspace/target/aarch64-unknown-linux-gnu/minimize/',
                })
            end
            filter({ 'options:not flutter_runtime' })
            do
                links({
                    'luau_analyzer',
                    'rive_scripting_workspace',
                    'rasc_front',
                    'spirv_cross',
                    'rust_ffi',
                    'brotli',
                    'rive_pathops',
                    'rml',
                    'rive_codec',
                })
            end
            filter({})
            defines({ 'RIVE_NATIVE_SHARED' })
        else
            kind('StaticLib')
            filter({ 'options:not flutter_runtime' })
            do
                dependson({ 'spirv_cross', 'rive_pathops', 'rml', 'rive_codec' })
            end
            filter({})
        end
    else
        kind('ConsoleApp')

        links({
            'GL',
            'rive',
            'rive_harfbuzz',
            'rive_sheenbidi',
            'rive_yoga',
            'rive_pls_renderer',
            'embind',
            'luau_vm',
            'luau_compiler',
            'miniaudio',
        })
        filter({ 'options:not flutter_runtime', 'options:arch=wasm', 'options:not single-threaded' })
        do
            libdirs({
                '../../scripting_workspace/target/wasm32-unknown-emscripten/minimize_web_threaded/',
            })
        end
        filter({ 'options:not flutter_runtime', 'options:arch=wasm', 'options:single-threaded' })
        do
            libdirs({
                '../../scripting_workspace/target/wasm32-unknown-emscripten/minimize_web/',
            })
        end
        filter({ 'options:not flutter_runtime' })
        do
            links({
                'luau_analyzer',
                'rive_scripting_workspace',
                'rasc_front',
                'spirv_cross',
                'rust_ffi',
                'brotli',
                'rive_pathops',
                'rml',
                'rive_codec',
            })
        end
        filter({})
        linkoptions({
            '-s USE_WEBGL2=1',
            '-s MIN_WEBGL_VERSION=2',
            '-s MAX_WEBGL_VERSION=2',
            -- Lets a worker pthread own a WebGL context on a transferred
            -- OffscreenCanvas, which the deferred replay worker needs.
            '-s OFFSCREENCANVAS_SUPPORT=1',
            -- '-s LEGACY_GL_EMULATION',
            '-s ASSERTIONS=0',
            -- '--closure=1',
            '--closure-args="--externs ../../../platform/wasm/externs.js"',
            '-s STACK_SIZE=256kb',
            '-s INITIAL_MEMORY=64mb',
            -- '-s TOTAL_MEMORY=512mb',
            '-s FORCE_FILESYSTEM=0',
            -- '-DANSI_DECLARATORS',
            '-s WASM_BIGINT',
            '-s MODULARIZE=1',
            '-s NO_EXIT_RUNTIME=1',
            -- we need instantiateWasm here until the fix here is in a tagged version
            -- https://github.com/emscripten-core/emscripten/issues/21844
            -- noExitRuntime must stay listed: without it emsdk 4 makes
            -- keepRuntimeAlive counter-only under pthreads, so the main thread
            -- exits the runtime and terminates the replay worker.
            '-s INCOMING_MODULE_JS_API=onRuntimeInitialized,instantiateWasm,noExitRuntime',
            '-s EXPORTED_RUNTIME_METHODS=wasmMemory,lengthBytesUTF8,stringToUTF8',
            '-s EXPORTED_FUNCTIONS=_malloc,_free',
            '-s ALLOW_MEMORY_GROWTH=1',
            '-s WASM=1',
            -- emsdk 4 removed USE_ES6_IMPORT_META; import.meta is unconditional
            -- now, so the glue is post-processed instead.
            '-DEMSCRIPTEN_HAS_UNBOUND_TYPE_NAMES=0',
            '--bind',
            '-s EXPORT_NAME="RiveNative"',
            '--no-entry',
            '-o ' .. path.getabsolute(RIVE_BUILD_OUT) .. '/rive_native.js',
            '--pre-js ' .. path.getabsolute('./platform/wasm/init.js'),
            '-fno-rtti',
            '-O3',
        })
        if withWasmBackend then
            -- Script modules run on the browser's wasm engine; this is the
            -- page side of that, generated in the runtime.
            linkoptions({
                '--pre-js ' .. path.getabsolute(
                    '../../runtime/src/wasm/web/rive_scripting_pre.js'
                ),
            })
        end
        buildoptions({
            '-s STRICT=1',
            '-s DISABLE_EXCEPTION_CATCHING=1',
            '-DEMSCRIPTEN_HAS_UNBOUND_TYPE_NAMES=0',
            '--no-entry',
        })
    end

    defines({ 'YOGA_EXPORT=' })
    includedirs({
        './include',
        'src/',
        packages .. '/runtime/include',
        packages .. '/runtime/renderer/include',
        packages .. '/runtime/decoders/include',
        packages .. '/runtime',
        yoga,
        miniaudio,
    })
    files({
        'src/rive_binding.cpp',
        'src/rive_audio_binding.cpp',
        'src/layout_engine_binding.cpp',
        'src/renderer_binding.cpp',
        'src/flutter_renderer.cpp',
        'src/text_binding.cpp',
        'src/text_selection_binding.cpp',
    })
    filter({ 'options:not flutter_runtime' })
    do
        files({
            'src/pathops_binding.cpp',
            'src/rml_binding.cpp',
        })
        if scriptingVm ~= 'wasm' then
            files({
                'src/rive_luau_binding.cpp',
                'src/rive_luau_binding_gpu.cpp',
            })
        end
        if withWasmBackend then
            files({ 'src/rive_wasm_binding.cpp' })
        end
        -- The workspace bindings compile here and hand out its std.
        if RIVE_RASC_BUNDLE_STD then
            defines({ 'WITH_RASC_STD_BUNDLE' })
        end
        includedirs({
            packages .. '/pathops/include',
            packages .. '/rml/include',
            packages .. '/rml',
            packages .. '/rive_codec/include',
        })
    end
    -- The Luau-free deferred session/consumer plumbing ships in the runtime
    -- too: deferred rendering is default and the runtime drives it through
    -- these exports.
    filter({ 'options:with_rive_canvas' })
    do
        files({
            'src/deferred_binding.cpp',
            'src/deferred_host.cpp',
        })
    end
    filter({})
    if _OPTIONS['arch'] == 'wasm' then
        files({
            'platform/wasm/*.cpp',
        })
    else
        filter({})
        do
            files({
                'src/read_write_ring.cpp',
            })
        end
        filter({ 'system:windows' })
        do
            -- `dxguid` provides the GUID symbols (e.g.
            -- `WKPDID_D3DDebugObjectName`) declared in `<d3d11.h>` /
            -- `<d3d12.h>`. Required by the Ore D3D11 backend's
            -- `SetPrivateData(WKPDID_D3DDebugObjectName, ...)` debug-label
            -- plumbing — without it `lld-link` reports an undefined
            -- symbol on the rive_native shared-library link step.
            links({ 'd3d11', 'd3d12', 'd3dcompiler', 'dxguid' })
            files({
                'platform/windows/rive_native_windows.cpp',
            })
        end
        filter({ 'system:windows', 'options:not flutter_runtime' })
        do
            libdirs({
                '../../scripting_workspace/target/x86_64-pc-windows-msvc/minimize/',
            })
            links({
                'luau_analyzer',
                'rive_scripting_workspace',
                'rasc_front',
                'spirv_cross',
                'rust_ffi',
                'ntdll',
                'bcrypt',
            })
        end
        filter({ 'system:macosx' })
        do
            files({
                'platform/mac/**.m',
                'platform/mac/**.mm',
                'src/pls_binding.mm',
            })
            links({
                'Cocoa.framework',
                'IOKit.framework',
                'CoreVideo.framework',
            })
        end

        -- Headless rendering is only for tests, not shipped in flutter_runtime.
        filter({ 'system:macosx', 'options:not flutter_runtime' })
        do
            files({
                'src/headless_rendering.mm',
            })
        end

        filter({ 'system:macosx' })
        do
            links({ 'Metal.framework', 'MetalKit.framework', 'QuartzCore.framework' })
        end

        filter({ 'system:ios' })
        do
            files({
                'platform/ios/**.m',
                'platform/ios/**.mm',
                'src/pls_binding.mm',
            })
        end

        filter({ 'system:android' })
        do
            defines({
                'SUPPORT_OPENGL',
                'RIVE_GLES',
            })
            -- Support 16 KB page sizes
            -- Necessary for NDK r27, can remove when upgrading to r28+
            -- See: https://developer.android.com/guide/practices/page-sizes#compile-r27
            -- See: https://android.googlesource.com/platform/ndk/+/master/docs/BuildSystemMaintainers.md#page-sizes
            linkoptions({ '-Wl,-z,max-page-size=16384' })
            links({ 'GLESv3', 'EGL', 'log', 'android' })
            files({
                'platform/android/rive_native_android.cpp',
            })
        end

        filter({ 'system:linux' })
        do
            defines({
                'SUPPORT_OPENGL',
                'RIVE_DESKTOP_GL',
            })
            includedirs({
                packages .. '/runtime/renderer/glad',
                packages .. '/runtime/renderer/glad/include',
            })
            links({ 'GL', 'dl' })
            files({
                'platform/linux/rive_native_linux.cpp',
            })
        end
    end
    filter({ 'options:not no-rive-decoders' })
    do
        dependson({ 'rive_decoders' })
    end
    filter({ 'options:not no-yoga-renames' })
    do
        includedirs({
            dependencies,
        })
        forceincludes({ 'rive_yoga_renames.h' })
    end

    if _OPTIONS['with_microprofile'] then
        includedirs({ microprofile })
    end

    filter({ 'options:not flutter_runtime' })
    do
        includedirs({
            packages .. '/scripting_workspace/include',
            packages .. '/scripting_workspace/naga_ffi',
            luau .. '/Compiler/include',
            luau .. '/VM/include',
            luau .. '/Common/include',
            luau .. '/Analysis/include',
            luau .. '/Config/include',
            luau .. '/Ast/include',
            brotli .. '/c/include',
        })
        files({ packages .. '/scripting_workspace/src/*.cpp' })

        -- luau needs this on
        exceptionhandling('On')
    end
end

newoption({
    trigger = 'shared',
    description = 'builds a shared lib',
})

newoption({
    trigger = 'single-threaded',
    description = 'no multithreading',
})

newoption({
    trigger = 'flutter_runtime',
    description = 'True when compiling for the flutter runtime.',
})
