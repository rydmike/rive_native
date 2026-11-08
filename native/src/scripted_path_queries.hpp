#ifndef _RIVE_NATIVE_SCRIPTED_PATH_QUERIES_HPP_
#define _RIVE_NATIVE_SCRIPTED_PATH_QUERIES_HPP_

#include "rive/math/raw_path.hpp"
#include "rive/renderer.hpp"
#include "rive/renderer/cmd/deferred_render_resource.hpp"

// A scripted effect's result is read back as a RawPath by whatever consumes it
// next (the next effect in a group/chain, hit testing, measuring). Deferred
// paths keep no readable geometry unless they opt in, so mirror what
// renderer_binding.cpp does for the trim/dash effect paths. Without this the
// consumer sees an empty path.
//
// The seed is pruned to match what renderPath() recorded through
// addUntrustedRawPath. That copy sits behind the cast so factories with no
// deferred path, and builds without path queries, don't pay for it.
inline void retainScriptedPathQueries(
    rive::RenderPath* path,
    const rive::RawPath& seed)
{
#ifdef WITH_RIVE_PATH_QUERY
  auto* deferred = rive::lite_rtti_cast<rive::cmd::DeferredRenderPath*>(path);
  if (deferred != nullptr)
  {
    rive::RawPath queryGeometry(seed);
    queryGeometry.pruneEmptySegments();
    deferred->retainQueryGeometry(&queryGeometry);
  }
#endif
}

#endif
