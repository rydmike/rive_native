#include "rive_native/external.hpp"
#include "rive_native/rive_binding.hpp"
#include "rive/shapes/paint/color.hpp"
#include "rive/core/binary_reader.hpp"
#include "rive/shapes/paint/trim_path.hpp"
#include "rive/shape_paint_type.hpp"
#include "rive/shapes/paint/dash_path.hpp"
#include "renderer/src/rive_render_path.hpp"
#include "rive/math/hit_test.hpp"
#include "rive/math/path_measure.hpp"
#include "rive/shapes/paint/dash.hpp"
#include "rive/renderer/cmd/deferred_render_resource.hpp"
#include "rive/bitmap_cache.hpp"
#ifdef RIVE_CANVAS
#include "rive/factory.hpp"
#include "rive/offscreen_raster.hpp"
#include "rive/renderer/cmd/deferred_canvas_host.hpp"
#include "rive/renderer/render_canvas.hpp"
#include <unordered_map>
#endif

const rive::RawPath& renderPathToRawPath(
    rive::Factory* factory,
    rive::RenderPath* renderPath);
const rive::FillRule renderPathFillRule(
    rive::Factory* factory,
    rive::RenderPath* renderPath);

static rive::RawPath buildingPath;

// Paths built directly through these bindings get hit tested and measured by
// the host, so opt them into query geometry. File loads never pass through
// here and stay twin free.
static void retainPathQueries(
    rive::RenderPath* path,
    const rive::RawPath* seed = nullptr)
{
#ifdef WITH_RIVE_PATH_QUERY
  auto* deferred = rive::lite_rtti_cast<rive::cmd::DeferredRenderPath*>(path);
  if (deferred != nullptr)
  {
    deferred->retainQueryGeometry(seed);
  }
#endif
}

static rive::Vec2D readVec2(rive::BinaryReader& reader)
{
  float x = reader.readFloat32();
  float y = reader.readFloat32();
  return rive::Vec2D(x, y);
}

const int scratchBufferSize = 1024;
EXPORT void appendCommands(uint8_t* memory, uint32_t commands)
{
  rive::BinaryReader reader(rive::Span<uint8_t>(memory, scratchBufferSize));
  for (int i = 0; i < commands; i++)
  {
    rive::PathVerb verb = (rive::PathVerb)reader.readByte();

    switch (verb)
    {
      case rive::PathVerb::move:
      {
        auto v = readVec2(reader);
        buildingPath.move(v);
        break;
      }
      case rive::PathVerb::line:
      {
        auto v = readVec2(reader);
        buildingPath.line(v);
        break;
      }
      case rive::PathVerb::quad:
      {
        auto control = readVec2(reader);
        auto to = readVec2(reader);
        buildingPath.quad(control, to);
        break;
      }
      case rive::PathVerb::cubic:
      {
        auto control1 = readVec2(reader);
        auto control2 = readVec2(reader);
        auto to = readVec2(reader);
        buildingPath.cubic(control1, control2, to);
        break;
      }
      case rive::PathVerb::close:
        buildingPath.close();
        break;
    }
  }
}

class DashPathEffect : public rive::PathDasher
{
public:
  rive::ShapePaintPath* effectPath(const rive::ShapePaintPath* source)
  {
    return dash(
        m_dashEffectPath.path(),
        source->rawPath(),
        &m_dashEffectPath.pathMeasure(),
        &m_offset,
        m_dashes);
  }

  rive::ShapePaintPath* effectPath(const rive::RawPath* source)
  {
    return dash(
        m_dashEffectPath.path(),
        source,
        &m_dashEffectPath.pathMeasure(),
        &m_offset,
        m_dashes);
  }

  void offset(float value, bool isPercentage)
  {
    m_offset.length(value);
    m_offset.lengthIsPercentage(isPercentage);
    m_dashEffectPath.invalidateEffect();
  }

  float offsetValue() { return m_offset.length(); }
  float offsetIsPercentage() { return m_offset.lengthIsPercentage(); }

  void clearDashes()
  {
    for (auto dash : m_dashes)
    {
      delete dash;
    }
    m_dashes.clear();
    m_dashEffectPath.invalidateEffect();
  }

  void addDash(float value, bool percentage)
  {
    m_dashes.emplace_back(new rive::Dash(value, percentage));
    m_dashEffectPath.invalidateEffect();
  }

  void invalidate() { m_dashEffectPath.invalidateEffect(); }
  rive::DashEffectPath* dashEffectPath() { return &m_dashEffectPath; }

private:
  rive::Dash m_offset;
  std::vector<rive::Dash*> m_dashes;
  rive::DashEffectPath m_dashEffectPath;
};

EXPORT rive::RenderPath* dashPathEffectPath(
    rive::Factory* factory,
    DashPathEffect* dashPath,
    rive::RenderPath* renderPath)
{
  if (dashPath == nullptr || renderPath == nullptr)
  {
    return nullptr;
  }
  assert(factory != nullptr);
  const rive::RawPath& rawPath = renderPathToRawPath(factory, renderPath);
  dashPath->dashEffectPath()->createPathMeasure(&rawPath);
  auto resultPath = dashPath->effectPath(&rawPath);
  auto resultRenderPath = resultPath->renderPath(factory);
  retainPathQueries(resultRenderPath, resultPath->rawPath());
  resultRenderPath->ref();
  return resultRenderPath;
}

EXPORT DashPathEffect* makeDashPathEffect() { return new DashPathEffect(); }
EXPORT void deleteDashPathEffect(DashPathEffect* dashPath) { delete dashPath; }

EXPORT float dashPathEffectGetPathLength(DashPathEffect* dashPath)
{
  if (dashPath == nullptr)
  {
    return 0.0f;
  }
  return dashPath->dashEffectPath()->pathMeasure().length();
}

EXPORT void dashPathEffectSetOffset(DashPathEffect* dashPath, float offset)
{
  if (dashPath == nullptr)
  {
    return;
  }
  dashPath->offset(offset, dashPath->offsetIsPercentage());
}

EXPORT float dashPathEffectGetOffset(DashPathEffect* dashPath)
{
  if (dashPath == nullptr)
  {
    return 0.0f;
  }
  return dashPath->offsetValue();
}

EXPORT void dashPathEffectSetOffsetIsPercentage(
    DashPathEffect* dashPath,
    bool isPercentage)
{
  if (dashPath == nullptr)
  {
    return;
  }
  dashPath->offset(dashPath->offsetValue(), isPercentage);
}

EXPORT bool dashPathEffectGetOffsetIsPercentage(DashPathEffect* dashPath)
{
  if (dashPath == nullptr)
  {
    return false;
  }
  return dashPath->offsetIsPercentage();
}

EXPORT void dashPathClearDashes(DashPathEffect* dashPath)
{
  if (dashPath == nullptr)
  {
    return;
  }
  dashPath->clearDashes();
}

EXPORT void dashPathAddDash(
    DashPathEffect* dashPath,
    float distance,
    bool isPercentage)
{
  if (dashPath == nullptr)
  {
    return;
  }
  dashPath->addDash(distance, isPercentage);
}

EXPORT void dashPathInvalidate(DashPathEffect* dashPath)
{
  if (dashPath == nullptr)
  {
    return;
  }
  dashPath->invalidate();
}

class EditorTrimPath : public rive::TrimPath
{
public:
  rive::ShapePaintPath* editorEffectPath(
      const rive::RawPath* source,
      int shapePaintType)
  {
    auto path = m_trimEffectPath.path();
    if (path->hasRenderPath())
    {
      // Previous result hasn't been invalidated, it's still good.
      return path;
    }
    trimPath(
        path,
        m_trimEffectPath.contours(),
        source,
        static_cast<rive::ShapePaintType>(shapePaintType));

    return path;
  }

  void invalidate() { m_trimEffectPath.invalidateEffect(); }

private:
  rive::TrimEffectPath m_trimEffectPath;
};
EXPORT EditorTrimPath* makeTrimPathEffect() { return new EditorTrimPath(); }

EXPORT void trimPathEffectSetStart(EditorTrimPath* trimPath, float start)
{
  if (trimPath == nullptr)
  {
    return;
  }
  trimPath->start(start);
}

EXPORT float trimPathEffectGetStart(EditorTrimPath* trimPath)
{
  if (trimPath == nullptr)
  {
    return 0.0f;
  }
  return trimPath->start();
}

EXPORT void trimPathEffectSetEnd(EditorTrimPath* trimPath, float end)
{
  if (trimPath == nullptr)
  {
    return;
  }
  trimPath->end(end);
}

EXPORT float trimPathEffectGetEnd(EditorTrimPath* trimPath)
{
  if (trimPath == nullptr)
  {
    return 0.0f;
  }
  return trimPath->end();
}

EXPORT void trimPathEffectSetOffset(EditorTrimPath* trimPath, float offset)
{
  if (trimPath == nullptr)
  {
    return;
  }
  trimPath->offset(offset);
}

EXPORT float trimPathEffectGetOffset(EditorTrimPath* trimPath)
{
  if (trimPath == nullptr)
  {
    return 0.0f;
  }
  return trimPath->offset();
}

EXPORT void trimPathEffectSetMode(EditorTrimPath* trimPath, uint8_t mode)
{
  if (trimPath == nullptr)
  {
    return;
  }
  trimPath->modeValue(mode);
}

EXPORT uint8_t trimPathEffectGetMode(EditorTrimPath* trimPath)
{
  if (trimPath == nullptr)
  {
    return 0;
  }
  return trimPath->modeValue();
}

EXPORT void trimPathEffectInvalidate(EditorTrimPath* trimPath)
{
  if (trimPath == nullptr)
  {
    return;
  }
  trimPath->invalidate();
}

EXPORT void deleteTrimPathEffect(EditorTrimPath* trimPath) { delete trimPath; }

EXPORT rive::RenderPath* trimPathEffectPath(
    rive::Factory* factory,
    EditorTrimPath* trimPath,
    rive::RenderPath* renderPath,
    int shapePaintType)
{
  if (trimPath == nullptr || renderPath == nullptr)
  {
    return nullptr;
  }
  assert(factory != nullptr);
  const rive::RawPath& rawPath = renderPathToRawPath(factory, renderPath);
  auto resultPath = trimPath->editorEffectPath(&rawPath, shapePaintType);
  auto resultRenderPath = resultPath->renderPath(factory);
  retainPathQueries(resultRenderPath, resultPath->rawPath());
  resultRenderPath->ref();
  return resultRenderPath;
}

EXPORT void deleteRenderPath(rive::RenderPath* renderPath)
{
  if (renderPath == nullptr)
  {
    return;
  }
  renderPath->unref();
}

EXPORT rive::RenderPath* makeRenderPath(rive::Factory* factory)
{
  assert(factory != nullptr);

  rive::rcp<rive::RenderPath> renderPath = factory->makeRenderPath(
      buildingPath,
      rive::FillRule::nonZero);
  retainPathQueries(renderPath.get(), &buildingPath);
  buildingPath.rewind();
  return renderPath.release();
}

EXPORT void appendRenderPath(rive::RenderPath* path)
{
  if (path == nullptr)
  {
    return;
  }
  buildingPath.addTo(path);
  buildingPath.rewind();
}

EXPORT rive::RenderPath* makeEmptyRenderPath(rive::Factory* factory)
{
  assert(factory != nullptr);
  rive::rcp<rive::RenderPath> renderPath = factory->makeEmptyRenderPath();
  retainPathQueries(renderPath.get());
  return renderPath.release();
}

EXPORT void rewindRenderPath(rive::RenderPath* path)
{
  if (path == nullptr)
  {
    return;
  }
  path->rewind();
}

EXPORT void renderPathSetFillRule(rive::RenderPath* path, uint8_t fillRule)
{
  if (path == nullptr)
  {
    return;
  }
  path->fillRule((rive::FillRule)fillRule);
}

EXPORT void drawPath(
    rive::Renderer* renderer,
    rive::RenderPath* path,
    rive::RenderPaint* paint)
{
  if (renderer == nullptr || path == nullptr)
  {
    return;
  }
  renderer->drawPath(path, paint);
}

static rive::ImageSampler samplerFromKey(uint8_t samplerKey)
{
  return samplerKey < rive::ImageSampler::MAX_SAMPLER_PERMUTATIONS
             ? rive::ImageSampler::SamplerFromKey(samplerKey)
             : rive::ImageSampler::LinearClamp();
}

EXPORT void drawImage(
    rive::Renderer* renderer,
    rive::RenderImage* image,
    uint8_t samplerKey,
    uint8_t blendModeValue,
    float opacity,
    float additiveness)
{
  if (renderer == nullptr || image == nullptr)
  {
    return;
  }
  renderer->drawImage(
      image,
      samplerFromKey(samplerKey),
      (rive::BlendMode)blendModeValue,
      opacity,
      additiveness);
}

EXPORT void drawImageMesh(
    rive::Renderer* renderer,
    rive::RenderImage* image,
    rive::RenderBuffer* vertices,
    rive::RenderBuffer* uvs,
    rive::RenderBuffer* indices,
    uint32_t vertexCount,
    uint32_t indexCount,
    uint8_t samplerKey,
    uint8_t blendModeValue,
    float opacity,
    float additiveness)
{
  if (renderer == nullptr || image == nullptr || vertices == nullptr ||
      uvs == nullptr || indices == nullptr || indexCount == 0)
  {
    return;
  }
  renderer->drawImageMesh(
      image,
      samplerFromKey(samplerKey),
      ref_rcp(vertices),
      ref_rcp(uvs),
      ref_rcp(indices),
      vertexCount,
      indexCount,
      (rive::BlendMode)blendModeValue,
      opacity,
      additiveness);
}

// The host writes instances as a flat float array over the pointer that
// editImageMeshInstances hands back, so these asserts are here to make sure
// the native struct doesn't fall out of sync with that float array.
static_assert(sizeof(rive::ImageMeshInstanceData) == 12 * sizeof(float));
static_assert(offsetof(rive::ImageMeshInstanceData, transform) == 0);
static_assert(
    offsetof(rive::ImageMeshInstanceData, uvTranslate) == 6 * sizeof(float));
static_assert(
    offsetof(rive::ImageMeshInstanceData, uvScale) == 8 * sizeof(float));
static_assert(
    offsetof(rive::ImageMeshInstanceData, opacity) == 10 * sizeof(float));
static_assert(
    offsetof(rive::ImageMeshInstanceData, additiveness) == 11 * sizeof(float));

EXPORT rive::ImageMeshInstances* makeImageMeshInstances(
    rive::Factory* factory,
    uint32_t count)
{
  assert(factory != nullptr);
  return factory->makeImageMeshInstances(count).release();
}

EXPORT float* editImageMeshInstances(
    rive::ImageMeshInstances* instances,
    uint32_t count)
{
  if (instances == nullptr)
  {
    return nullptr;
  }
  return reinterpret_cast<float*>(instances->edit(count).data());
}

EXPORT void endEditImageMeshInstances(rive::ImageMeshInstances* instances)
{
  if (instances == nullptr)
  {
    return;
  }
  instances->endEdit();
}

EXPORT void deleteImageMeshInstances(rive::ImageMeshInstances* instances)
{
  if (instances == nullptr)
  {
    return;
  }
  instances->unref();
}

EXPORT void drawImageMeshInstanced(
    rive::Renderer* renderer,
    rive::RenderImage* image,
    rive::RenderBuffer* vertices,
    rive::RenderBuffer* uvs,
    rive::RenderBuffer* indices,
    uint32_t vertexCount,
    uint32_t indexCount,
    uint8_t samplerKey,
    rive::ImageMeshInstances* instances)
{
  if (renderer == nullptr || image == nullptr || vertices == nullptr ||
      uvs == nullptr || indices == nullptr || indexCount == 0 ||
      instances == nullptr)
  {
    return;
  }
  renderer->drawImageMeshInstanced(
      image,
      samplerFromKey(samplerKey),
      ref_rcp(vertices),
      ref_rcp(uvs),
      ref_rcp(indices),
      vertexCount,
      indexCount,
      ref_rcp(instances));
}

EXPORT void clipPath(rive::Renderer* renderer, rive::RenderPath* path)
{
  if (path == nullptr || renderer == nullptr)
  {
    return;
  }
  renderer->clipPath(path);
}

EXPORT void save(rive::Renderer* renderer)
{
  if (renderer == nullptr)
  {
    return;
  }
  renderer->save();
}

EXPORT void restore(rive::Renderer* renderer)
{
  if (renderer == nullptr)
  {
    return;
  }
  renderer->restore();
}

EXPORT void transform(
    rive::Renderer* renderer,
    float x1,
    float y1,
    float x2,
    float y2,
    float tx,
    float ty)
{
  if (renderer == nullptr)
  {
    return;
  }
  rive::Mat2D matrix(x1, y1, x2, y2, tx, ty);
  renderer->transform(matrix);
}

EXPORT void modulateOpacity(rive::Renderer* renderer, float opacity)
{
  if (renderer == nullptr)
  {
    return;
  }
  renderer->modulateOpacity(opacity);
}

EXPORT void addRawPath(rive::RenderPath* to, rive::RawPath* rawPath)
{
  if (to == nullptr || rawPath == nullptr)
  {
    return;
  }
  rawPath->addTo(to);
}

EXPORT void addRawPathWithTransform(
    rive::RenderPath* to,
    rive::RawPath* rawPath,
    float x1,
    float y1,
    float x2,
    float y2,
    float tx,
    float ty)
{
  if (to == nullptr || rawPath == nullptr)
  {
    return;
  }
  rive::Mat2D matrix(x1, y1, x2, y2, tx, ty);
  rawPath->transform(matrix).addTo(to);
}

EXPORT void addRawPathWithTransformClockwise(
    rive::RenderPath* to,
    rive::RawPath* rawPath,
    float x1,
    float y1,
    float x2,
    float y2,
    float tx,
    float ty)
{
  if (to == nullptr || rawPath == nullptr)
  {
    return;
  }
  // Assumes rawPath is clockwise already.
  rive::Mat2D matrix(x1, y1, x2, y2, tx, ty);
  if (matrix.determinant() >= 0)
  {
    rawPath->transform(matrix).addTo(to);
  }
  else
  {
    rive::RawPath scratchPath;
    scratchPath.addPathBackwards(*rawPath, &matrix);
    scratchPath.addTo(to);
  }
}

EXPORT void addPath(
    rive::RenderPath* to,
    rive::RenderPath* path,
    float x1,
    float y1,
    float x2,
    float y2,
    float tx,
    float ty)
{
  if (to == nullptr || path == nullptr)
  {
    return;
  }
  rive::Mat2D matrix(x1, y1, x2, y2, tx, ty);
  to->addPath(path, matrix);
}

EXPORT void addPathBackwards(
    rive::Factory* factory,
    rive::RenderPath* to,
    rive::RenderPath* path,
    float x1,
    float y1,
    float x2,
    float y2,
    float tx,
    float ty)
{
  if (to == nullptr || path == nullptr)
  {
    return;
  }
  assert(factory != nullptr);
  const rive::RawPath& rawPath = renderPathToRawPath(factory, path);
  rive::RawPath backwardsRawPath;
  rive::Mat2D matrix(x1, y1, x2, y2, tx, ty);
  if (rawPath.empty())
  {
    return;
  }

  backwardsRawPath.addPathBackwards(rawPath, &matrix);
  backwardsRawPath.addTo(to);
}

EXPORT rive::RenderPaint* makeRenderPaint(rive::Factory* factory)
{
  assert(factory != nullptr);
  rive::rcp<rive::RenderPaint> paint = factory->makeRenderPaint();
  return paint.release();
}

EXPORT void deleteRenderPaint(rive::RenderPaint* paint)
{
  if (paint != nullptr)
  {
    paint->unref();
  }
}

EXPORT void paintModulatedImage(
    rive::RenderPaint* paint,
    rive::RenderImage* image,
    uint8_t samplerKey,
    float xx,
    float xy,
    float yx,
    float yy,
    float tx,
    float ty)
{
  if (paint == nullptr)
  {
    return;
  }
  paint->modulatedImage(
      image,
      samplerFromKey(samplerKey),
      rive::Mat2D(xx, xy, yx, yy, tx, ty));
}

// Modulates [paint] with [paintSource]'s artboard, rasterized offscreen for
// [renderer] when it changed. Returns false, leaving [paint] untouched, when
// it cannot: this factory has no canvas host, the source lives on another
// factory (a thumbnail or standalone renderer has its own session, and a
// canvas from one cannot be sampled by another), or the host draws
// immediately and would need the path rerouted, which a Dart draw cannot do.
EXPORT bool paintModulatedArtboard(
    rive::Renderer* renderer,
    rive::Factory* factory,
    rive::RenderPaint* paint,
    WrappedArtboardPaintSource* paintSource,
    uint8_t samplerKey,
    float xx,
    float xy,
    float yx,
    float yy,
    float tx,
    float ty)
{
  if (renderer == nullptr || factory == nullptr || paint == nullptr ||
      paintSource == nullptr)
  {
    return false;
  }
  rive::ArtboardPaintSource* source = paintSource->source.get();
  if (source->artboard()->factory() != factory)
  {
    return false;
  }
  rive::ModulatedDrawTarget target;
  if (!source->applyTo(
          renderer,
          factory->canvasContentHost(),
          paint,
          samplerFromKey(samplerKey),
          rive::Mat2D(xx, xy, yx, yy, tx, ty),
          &target))
  {
    return false;
  }
  if (target.renderer != renderer)
  {
    paint->modulatedImage(
        nullptr,
        rive::ImageSampler::LinearClamp(),
        rive::Mat2D());
    return false;
  }
  return true;
}

// Stop count that tells us to drop the gradient.
constexpr uint16_t RemoveGradientStops = 0xFFFF;

enum PaintDirt : uint16_t
{
  style = 1 << 0,
  color = 1 << 1,
  thickness = 1 << 2,
  join = 1 << 3,
  cap = 1 << 4,
  blendMode = 1 << 5,
  radial = 1 << 6, // 0 == linear, 1 == radial only valid if stops != 0
  done = 1 << 7,   // 1 when no more gradien stops will follow
  feather = 1 << 8,
  additiveness = 1 << 9,
  strokePosition = 1 << 10,
  gradientTransform = 1 << 11,
  // A sweep. `radial` says linear or radial; this overrides both, and its
  // payload is the linear one, which makeAngularGradient does not read.
  angular = 1 << 12
  // Note: bit 15 (gradient) is Dart-side only; native ignores it.,
};

std::vector<rive::ColorInt> gradientColors;
std::vector<float> gradientStops;

EXPORT void updatePaint(
    rive::Factory* factory,
    rive::RenderPaint* paint,
    uint16_t flags,
    const uint8_t* memory,
    uint16_t stops)
{
  if (paint == nullptr)
  {
    return;
  }
  assert(factory != nullptr);
  // Update this if we change the buffer size in dart too.
  rive::BinaryReader reader(
      rive::Span<const uint8_t>(memory, scratchBufferSize));
  if ((flags & PaintDirt::style) != 0)
  {
    uint8_t style = reader.readByte();
    switch (style)
    {
      case 0:
        paint->style(rive::RenderPaintStyle::stroke);
        break;
      case 1:
        paint->style(rive::RenderPaintStyle::fill);
        break;
      case 2:
        paint->style(rive::RenderPaintStyle::fill);
        break;
    }
  }
  if ((flags & PaintDirt::color) != 0)
  {
    rive::ColorInt color = reader.readUint32();
    paint->color(color);
  }
  if ((flags & PaintDirt::thickness) != 0)
  {
    paint->thickness(reader.readFloat32());
  }
  if ((flags & PaintDirt::join) != 0)
  {
    paint->join((rive::StrokeJoin)reader.readByte());
  }
  if ((flags & PaintDirt::cap) != 0)
  {
    paint->cap((rive::StrokeCap)reader.readByte());
  }
  if ((flags & PaintDirt::blendMode) != 0)
  {
    uint8_t mode = reader.readByte();
    paint->blendMode(static_cast<rive::BlendMode>(mode));
  }
  if ((flags & PaintDirt::strokePosition) != 0)
  {
    uint8_t position = reader.readByte();
    if (position <= (uint8_t)rive::StrokePosition::outside)
    {
      paint->strokePosition(static_cast<rive::StrokePosition>(position));
    }
  }
  if ((flags & PaintDirt::gradientTransform) != 0)
  {
    rive::Mat2D gradientTransform(
        reader.readFloat32(),
        reader.readFloat32(),
        reader.readFloat32(),
        reader.readFloat32(),
        reader.readFloat32(),
        reader.readFloat32());
    paint->shaderTransform(gradientTransform);
  }
  if ((flags & PaintDirt::feather) != 0)
  {
    paint->feather(reader.readFloat32());
  }
  if ((flags & PaintDirt::additiveness) != 0)
  {
    paint->additiveness(reader.readFloat32());
  }
  // Stops are read last because they are the only thing that can span
  // multiple updatePaint calls.
  if (stops == RemoveGradientStops)
  {
    paint->shader(nullptr);
  }
  else if (stops != 0)
  {
    bool isRadial = (flags & PaintDirt::radial) != 0;
    bool isAngular = (flags & PaintDirt::angular) != 0;

    for (int i = 0; i < stops; i++)
    {
      gradientStops.push_back(reader.readFloat32());
      gradientColors.push_back((rive::ColorInt)reader.readUint32());
    }
    if ((flags & PaintDirt::done) != 0)
    {
      // Offsets packed at end
      if (isAngular)
      {
        // The start and end are read so the buffer stays in step,
        // and dropped: the factory takes colours and stops alone
        // until it grows a centre and an angle.
        reader.readFloat32();
        reader.readFloat32();
        reader.readFloat32();
        reader.readFloat32();
        paint->shader(factory->makeAngularGradient(
            gradientColors.data(),
            gradientStops.data(),
            gradientColors.size()));
      }
      else if (isRadial)
      {
        float cx = reader.readFloat32();
        float cy = reader.readFloat32();
        float radius = reader.readFloat32();
        paint->shader(factory->makeRadialGradient(
            cx,
            cy,
            radius,
            gradientColors.data(),
            gradientStops.data(),
            gradientColors.size()));
      }
      else
      {
        float sx = reader.readFloat32();
        float sy = reader.readFloat32();
        float ex = reader.readFloat32();
        float ey = reader.readFloat32();
        paint->shader(factory->makeLinearGradient(
            sx,
            sy,
            ex,
            ey,
            gradientColors.data(),
            gradientStops.data(),
            gradientColors.size()));
      }
      gradientStops.clear();
      gradientColors.clear();
    }
  }
}

EXPORT rive::RenderImage* decodeRenderImage(
    rive::Factory* factory,
    const uint8_t* bytes,
    uint64_t length)
{
  assert(factory != nullptr);
  auto image = factory->decodeImage(rive::Span(bytes, length));
  if (image)
  {
    return image.release();
  }
  return nullptr;
}

EXPORT int renderImageWidth(rive::RenderImage* image)
{
  if (image == nullptr)
  {
    return 0;
  }
  return image->width();
}

EXPORT int renderImageHeight(rive::RenderImage* image)
{
  if (image == nullptr)
  {
    return 0;
  }
  return image->height();
}

EXPORT void deleteRenderImage(rive::RenderImage* image)
{
  if (image == nullptr)
  {
    return;
  }
  image->unref();
}

EXPORT rive::RenderBuffer* makeVertexRenderBuffer(
    rive::Factory* factory,
    uint32_t vertexCount)
{
  assert(factory != nullptr);
  return factory
      ->makeRenderBuffer(
          rive::RenderBufferType::vertex,
          rive::RenderBufferFlags::none,
          vertexCount * sizeof(rive::Vec2D))
      .release();
}

EXPORT rive::RenderBuffer* makeIndexRenderBuffer(
    rive::Factory* factory,
    uint32_t indexCount)
{
  assert(factory != nullptr);
  return factory
      ->makeRenderBuffer(
          rive::RenderBufferType::index,
          rive::RenderBufferFlags::none,
          indexCount * sizeof(uint16_t))
      .release();
}

EXPORT void* mapRenderBuffer(rive::RenderBuffer* buffer)
{
  if (buffer == nullptr)
  {
    return nullptr;
  }
  return buffer->map();
}

EXPORT void unmapRenderBuffer(rive::RenderBuffer* buffer)
{
  if (buffer == nullptr)
  {
    return;
  }
  return buffer->unmap();
}

EXPORT void deleteRenderBuffer(rive::RenderBuffer* buffer)
{
  if (buffer == nullptr)
  {
    return;
  }
  buffer->unref();
}

EXPORT bool renderPathHitTest(
    rive::Factory* factory,
    rive::RenderPath* renderPath,
    float x,
    float y,
    float hitRadius,
    float x1,
    float y1,
    float x2,
    float y2,
    float tx,
    float ty)
{
  if (renderPath == nullptr)
  {
    return false;
  }
  assert(factory != nullptr);
  const rive::RawPath& rawPath = renderPathToRawPath(factory, renderPath);
  rive::Mat2D transform(x1, y1, x2, y2, tx, ty);

  auto hitArea = rive::AABB(
                     x - hitRadius,
                     y - hitRadius,
                     x + hitRadius,
                     y + hitRadius)
                     .round();

  rive::HitTester tester(hitArea);
  for (auto iter : rawPath)
  {
    rive::PathVerb verb = std::get<0>(iter);
    const rive::Vec2D* pts = std::get<1>(iter);
    switch (verb)
    {
      case rive::PathVerb::move:
        tester.move(transform * pts[0]);
        break;
      case rive::PathVerb::line:
        tester.line(transform * pts[1]);
        break;
      case rive::PathVerb::cubic:
        tester.cubic(
            transform * pts[1],
            transform * pts[2],
            transform * pts[3]);
        break;
      case rive::PathVerb::close:
        tester.close();
        break;
      case rive::PathVerb::quad:
        tester.cubic(
            transform * rive::Vec2D::lerp(pts[0], pts[1], 2 / 3.f),
            transform * rive::Vec2D::lerp(pts[2], pts[1], 2 / 3.f),
            transform * pts[2]);
        break;
    }
  }

  return tester.test(renderPathFillRule(factory, renderPath));
}

EXPORT bool renderPathIsClockwise(
    rive::Factory* factory,
    rive::RenderPath* renderPath,
    float matrixDeterminant)
{
  if (renderPath == nullptr)
  {
    return false;
  }
  assert(factory != nullptr);
  const rive::RawPath& rawPath = renderPathToRawPath(factory, renderPath);
  return rawPath.computeCoarseArea(rawPath.bounds().center()) *
             matrixDeterminant >=
         0;
}

EXPORT rive::PathMeasure* makePathMeasure(
    rive::Factory* factory,
    rive::RenderPath* renderPath,
    float tolerance)
{
  if (renderPath == nullptr)
  {
    return nullptr;
  }
  assert(factory != nullptr);
  const rive::RawPath& rawPath = renderPathToRawPath(factory, renderPath);
  return new rive::PathMeasure(&rawPath, tolerance);
}

EXPORT void deletePathMeasure(rive::PathMeasure* pathMeasure)
{
  delete pathMeasure;
}
EXPORT void pathMeasureAtDistance(
    rive::PathMeasure* pathMeasure,
    float distance,
    float* out)
{
  if (pathMeasure == nullptr)
  {
    return;
  }
  auto result = pathMeasure->atDistance(distance);
  memcpy(out, &result, sizeof(float) * 5);
}

EXPORT void pathMeasureAtPercentage(
    rive::PathMeasure* pathMeasure,
    float percentage,
    float* out)
{
  if (pathMeasure == nullptr)
  {
    return;
  }
  auto result = pathMeasure->atPercentage(percentage);
  memcpy(out, &result, sizeof(float) * 5);
}

EXPORT float pathMeasureLength(rive::PathMeasure* pathMeasure)
{
  if (pathMeasure == nullptr)
  {
    return 0.0f;
  }
  return pathMeasure->length();
}

EXPORT void renderPathPreciseBounds(
    rive::Factory* factory,
    rive::RenderPath* renderPath,
    float x1,
    float y1,
    float x2,
    float y2,
    float tx,
    float ty,
    float* out)
{
  if (renderPath == nullptr)
  {
    return;
  }
  assert(factory != nullptr);
  const rive::RawPath& rawPath = renderPathToRawPath(factory, renderPath);
  rive::Mat2D matrix(x1, y1, x2, y2, tx, ty);
  rive::AABB bounds = matrix != rive::Mat2D()
                          ? rawPath.transform(matrix).preciseBounds()
                          : rawPath.preciseBounds();
  memcpy(out, &bounds, sizeof(float) * 4);
}

EXPORT void renderPathBounds(
    rive::Factory* factory,
    rive::RenderPath* renderPath,
    float x1,
    float y1,
    float x2,
    float y2,
    float tx,
    float ty,
    float* out)
{
  if (renderPath == nullptr)
  {
    return;
  }
  assert(factory != nullptr);
  const rive::RawPath& rawPath = renderPathToRawPath(factory, renderPath);
  rive::Mat2D matrix(x1, y1, x2, y2, tx, ty);
  rive::AABB bounds = matrix != rive::Mat2D()
                          ? rawPath.transform(matrix).bounds()
                          : rawPath.bounds();
  memcpy(out, &bounds, sizeof(float) * 4);
}

EXPORT float renderPathPreciseLength(
    rive::Factory* factory,
    rive::RenderPath* renderPath,
    float x1,
    float y1,
    float x2,
    float y2,
    float tx,
    float ty)
{
  float l = 0.0;
  if (renderPath == nullptr)
  {
    return l;
  }
  assert(factory != nullptr);
  const rive::RawPath& rawPath = renderPathToRawPath(factory, renderPath);
  rive::Mat2D matrix(x1, y1, x2, y2, tx, ty);
  rive::RawPath source = rawPath.transform(matrix);
  rive::ContourMeasureIter iter(&source);
  while (auto contour = iter.next())
  {
    l += contour->length();
  }

  return l;
}

class ColinearCheck
{
public:
  const rive::Vec2D& pointA() { return m_pointA; }
  const rive::Vec2D& pointB() { return m_pointB; }

  bool addPoint(const rive::Vec2D& point)
  {
    if (m_pointCount == 0)
    {
      // Also seed pointB so degenerate paths (single point, all
      // duplicates) never report an uninitialized segment.
      m_pointA = m_pointB = point;
      m_pointCount++;
    }
    else if (m_pointCount == 1)
    {
      auto diff = point - m_pointA;
      if (diff.x == 0.0f && diff.y == 0.0f)
      {
        // Skip duplicates of the first point until a distinct point
        // establishes the line's direction.
        return true;
      }
      m_pointB = point;
      m_direction = diff.normalized();
      m_pointCount++;
    }
    else
    {
      // Sign-free collinearity: |cross| / |AP| is |sin| of the angle
      // between the A->B line and A->P. A signed slope comparison
      // breaks on vertical lines with points on both sides of A
      // (-inf vs +inf).
      auto diff = point - m_pointA;
      if (std::abs(rive::Vec2D::cross(m_direction, diff)) >
          0.1f * diff.length())
      {
        return false;
      }
    }

    return true;
  }

private:
  int m_pointCount = 0;
  rive::Vec2D m_pointA;
  rive::Vec2D m_pointB;
  rive::Vec2D m_direction;
};

EXPORT bool renderPathColinearCheck(
    rive::Factory* factory,
    rive::RenderPath* renderPath,
    float* out)
{
  if (renderPath == nullptr)
  {
    return false;
  }
  assert(factory != nullptr);
  const rive::RawPath& rawPath = renderPathToRawPath(factory, renderPath);

  ColinearCheck check;
  for (auto point : rawPath.points())
  {
    if (!check.addPoint(point))
    {
      return false;
    }
  }
  memcpy(out, &check.pointA(), sizeof(float) * 2);
  memcpy(out + 2, &check.pointB(), sizeof(float) * 2);
  return true;
}

EXPORT bool renderPathIsClosed(
    rive::Factory* factory,
    rive::RenderPath* renderPath)
{
  if (renderPath == nullptr)
  {
    return false;
  }
  assert(factory != nullptr);
  const rive::RawPath& rawPath = renderPathToRawPath(factory, renderPath);
  return rawPath.isClosed();
}

EXPORT bool renderPathHasBounds(
    rive::Factory* factory,
    rive::RenderPath* renderPath)
{
  if (renderPath == nullptr)
  {
    return false;
  }
  assert(factory != nullptr);
  const rive::RawPath& rawPath = renderPathToRawPath(factory, renderPath);
  for (auto iter : rawPath)
  {
    rive::PathVerb verb = std::get<0>(iter);
    switch (verb)
    {
      case rive::PathVerb::move:
        return true;
      case rive::PathVerb::line:
        return true;
      case rive::PathVerb::cubic:
        return true;
      case rive::PathVerb::close:
        break;
      case rive::PathVerb::quad:
        return true;
    }
  }
  return false;
}

EXPORT int32_t renderPathCopyBuffers(
    rive::Factory* factory,
    rive::RenderPath* renderPath,
    uint8_t* verbBuffer,
    uint32_t verbBufferSize,
    float* pointBuffer,
    uint32_t pointBufferSize)
{
  if (renderPath == nullptr)
  {
    return 0;
  }
  assert(factory != nullptr);
  const rive::RawPath& rawPath = renderPathToRawPath(factory, renderPath);
  if (verbBufferSize < (uint32_t)rawPath.verbs().size() ||
      pointBufferSize < (uint32_t)rawPath.points().size())
  {
    return -(int)rawPath.verbs().size();
  }
  memcpy((void*)verbBuffer, rawPath.verbs().data(), rawPath.verbs().size());
  memcpy(
      (void*)pointBuffer,
      (void*)rawPath.points().data(),
      sizeof(float) * 2 * rawPath.points().size());

  return (int32_t)rawPath.verbs().size();
}

#if defined(__EMSCRIPTEN__)
EXPORT uint8_t* allocateBuffer(uint32_t size) { return new uint8_t[size]; }
EXPORT void deleteBuffer(uint8_t* buffer) { delete[] buffer; }
#endif

// Deformed Components: the editor's mesh is Dart, the mounted artboard native,
// so Dart passes its mesh buffers in.

EXPORT void setOffscreenDisplayScale(float scale)
{
#ifdef RIVE_CANVAS
  rive::offscreen::setDisplayScale(scale);
#endif
}

// The live Bitmap Cache resolution, 1 without one.
EXPORT float artboardRasterResolution(WrappedArtboard* wrappedArtboard)
{
  if (wrappedArtboard == nullptr)
  {
    return 1.0f;
  }
  const rive::BitmapCache* cache = wrappedArtboard->artboard()->bitmapCache();
  return cache != nullptr ? cache->resolution() : 1.0f;
}

// The live rotation/scale an animation or data bind gives the instance.
EXPORT void artboardSelfTransform(WrappedArtboard* wrappedArtboard, float* out)
{
  const rive::Mat2D m = wrappedArtboard == nullptr
                            ? rive::Mat2D()
                            : wrappedArtboard->artboard()->selfTransform();
  memcpy(out, &m, sizeof(float) * 6);
}

// Writes the 0..1 UV to raster mapping into out[0..5].
EXPORT bool artboardMeshUVTransform(
    WrappedArtboard* wrappedArtboard,
    float resolution,
    float* out)
{
#ifdef RIVE_CANVAS
  if (wrappedArtboard == nullptr || out == nullptr)
  {
    return false;
  }
  rive::offscreen::RasterPlan plan;
  if (!rive::offscreen::planFixedRasterSize(
          wrappedArtboard->artboard()->bounds(),
          resolution,
          &plan))
  {
    return false;
  }
  const rive::Mat2D m = rive::Mat2D::fromScale(
      plan.box.width() * plan.rasterScale / static_cast<float>(plan.widthPx),
      plan.box.height() * plan.rasterScale / static_cast<float>(plan.heightPx));
  for (int i = 0; i < 6; i++)
  {
    out[i] = m[i];
  }
  return true;
#else
  return false;
#endif
}

// False when there's no offscreen host; the caller then draws undeformed.
EXPORT bool artboardDrawThroughMesh(
    WrappedArtboard* wrappedArtboard,
    rive::Renderer* renderer,
    float resolution,
    rive::RenderBuffer* vertices,
    rive::RenderBuffer* uvs,
    rive::RenderBuffer* indices,
    uint32_t vertexCount,
    uint32_t indexCount,
    uint8_t blendModeValue,
    float opacity)
{
#ifdef RIVE_CANVAS
  if (wrappedArtboard == nullptr || renderer == nullptr ||
      vertices == nullptr || uvs == nullptr || indices == nullptr ||
      indexCount == 0)
  {
    return false;
  }
  rive::ArtboardInstance* artboard = wrappedArtboard->artboard();
  rive::offscreen::CachedRaster& raster = wrappedArtboard->meshRaster;
  if (artboard->consumeInvisibleChange())
  {
    return true;
  }
  rive::offscreen::RasterPlan plan;
  rive::cmd::DeferredCanvasHost* host = nullptr;
  rive::rcp<rive::RenderImage> image = artboard->rasterImage(
      renderer,
      raster,
      resolution,
      /*fixedSize=*/true,
      &plan,
      &host);
  if (image == nullptr)
  {
    return false;
  }
  auto placement = rive::offscreen::beginPlacement(renderer, host, plan);
  placement.renderer->drawImageMesh(
      image.get(),
      rive::ImageSampler::LinearClamp(),
      ref_rcp(vertices),
      ref_rcp(uvs),
      ref_rcp(indices),
      vertexCount,
      indexCount,
      (rive::BlendMode)blendModeValue,
      opacity * placement.opacity,
      0.0f);
  rive::offscreen::endComposite(placement);
  return true;
#else
  return false;
#endif
}

// ---------------------------------------------------------------------------
// Layer masking
//
// The editor's design stage draws the ROOT artboard from Dart; everything
// nested is drawn by the C++ runtime and is already masked by
// Artboard::drawMasked. So what Dart needs is only the offscreen bracket for
// root-level drawables, exposed as three calls.
//
// The orchestration deliberately lives here rather than in Dart: the raster
// plan, the 2048 cap, the exact-scale inverse and the pixel snap are all in
// offscreen_raster.hpp and are pixel-proven. A Dart-side copy would drift.
//
//   beginMask       -> opens the CONTENT canvas, returns its renderer
//   beginMaskSource -> opens the COVERAGE canvas nested inside it
//   endMask         -> closes coverage, applies it to content, closes content,
//                      composites into the parent renderer
//
// The two brackets nest, which DeferredSession only learned to route correctly
// when it got its canvas stack; before that the inner close would have sent the
// rest of the outer content to the screen.
// ---------------------------------------------------------------------------
#ifdef RIVE_CANVAS
namespace
{
struct MaskCanvases
{
  rive::rcp<rive::gpu::RenderCanvas> content;
  rive::rcp<rive::gpu::RenderCanvas> coverage;
  uint32_t widthPx = 0;
  uint32_t heightPx = 0;
  // Consecutive calls that wanted a smaller pair. The editor needs this more
  // than the runtime does: dragging a shape on stage changes the box every
  // frame, and this map is unpooled, so every size change is two fresh driver
  // textures.
  uint8_t shrinkStreak = 0;
};

struct OpenMask
{
  rive::cmd::DeferredCanvasHost* host = nullptr;
  uint64_t handle = 0;
  rive::offscreen::RasterPlan plan;
  rive::LayerMaskMode mode = rive::LayerMaskMode::alpha;
  rive::Renderer* contentRenderer = nullptr;
  rive::Renderer* coverageRenderer = nullptr;
};

// Canvases persist across frames so a mask does not re-mint two textures every
// frame. Keyed by an opaque handle the caller owns, rather than by a core id,
// which is only unique within one file.
std::unordered_map<uint64_t, MaskCanvases>& maskCanvases()
{
  static std::unordered_map<uint64_t, MaskCanvases> map;
  return map;
}

// One open bracket per parent renderer. Nesting keys each level by a different
// parent (the enclosing mask's content renderer), so one entry each is enough.
std::unordered_map<rive::Renderer*, OpenMask>& openMasks()
{
  static std::unordered_map<rive::Renderer*, OpenMask> map;
  return map;
}

void applyRasterTransform(
    rive::Renderer* renderer,
    const rive::offscreen::RasterPlan& plan)
{
  renderer->save();
  renderer->transform(
      rive::Mat2D::fromScale(plan.rasterScale, plan.rasterScale));
  renderer->translate(-plan.box.left(), -plan.box.top());
}
} // namespace
#endif

// A key for one mask's retained canvases. The caller holds it for the mask
// object's lifetime and passes it back to rendererReleaseMask.
EXPORT uint64_t rendererAcquireMaskHandle()
{
  static uint64_t next = 1;
  return next++;
}

EXPORT void rendererReleaseMask(uint64_t handle)
{
#ifdef RIVE_CANVAS
  maskCanvases().erase(handle);
#endif
}

// Returns the renderer subsequent content draws must go through, or null when
// this renderer cannot mask -- in which case the caller draws the layer inline
// and must not call the other two.
EXPORT rive::Renderer* rendererBeginMask(
    rive::Renderer* renderer,
    rive::Factory* factory,
    uint64_t handle,
    uint8_t mode,
    float left,
    float top,
    float right,
    float bottom,
    float resolution)
{
#ifdef RIVE_CANVAS
  if (renderer == nullptr || factory == nullptr)
  {
    return nullptr;
  }
  // No host means nobody can give us an offscreen frame; the layer draws
  // unmasked, which is visible but not wrong.
  auto* host = factory->canvasContentHost();
  if (host == nullptr)
  {
    return nullptr;
  }
  // Same question Artboard::drawMasked asks, and for the same reason: a host
  // that cannot apply the op would leave the layer unmasked AND cropped to
  // the box planned below, so it has to be asked before anything is planned
  // or allocated.
  if (!host->supportsLayerMask())
  {
    return nullptr;
  }
  if (openMasks().count(renderer) != 0)
  {
    // A bracket is already open on this renderer; the caller lost track.
    return nullptr;
  }

  // stableGrid rather than a plain planRaster: the box Dart hands over is
  // measured from content now, so it moves and resizes as the author drags
  // things. The texel snap keeps sub-pixel motion smooth, the guard band
  // keeps the composite from smearing the edge texel, and the bucketing plus
  // the hysteresis below keep a drag from minting two textures per frame.
  rive::offscreen::RasterPlan plan;
  rive::AABB box(left, top, right, bottom);
  if (!rive::offscreen::planRasterScale(renderer, resolution, &plan))
  {
    return nullptr;
  }
  constexpr uint32_t kGuardTexels = 2;
  if (!rive::offscreen::fitRasterToBox(
          box,
          kGuardTexels,
          rive::offscreen::RasterFit::stableGrid,
          &plan))
  {
    return nullptr;
  }

  MaskCanvases& canvases = maskCanvases()[handle];
  const rive::offscreen::RasterResize
      resize = rive::offscreen::decideRasterResize(
          plan.widthPx,
          plan.heightPx,
          canvases.widthPx,
          canvases.heightPx,
          &canvases.shrinkStreak);
  rive::offscreen::holdRasterAllocation(resize.widthPx, resize.heightPx, &plan);
  if (resize.reallocate || canvases.content == nullptr ||
      canvases.coverage == nullptr)
  {
    canvases.content = host->makeContentCanvas(plan.widthPx, plan.heightPx);
    canvases.coverage = host->makeContentCanvas(plan.widthPx, plan.heightPx);
    canvases.widthPx = plan.widthPx;
    canvases.heightPx = plan.heightPx;
  }
  if (canvases.content == nullptr || canvases.coverage == nullptr)
  {
    maskCanvases().erase(handle);
    return nullptr;
  }

  rive::Renderer* contentRenderer = host->beginCanvasContent(
      canvases.content.get(),
      0);
  if (contentRenderer == nullptr)
  {
    // Nothing was drawn and no bracket began, so there is none to end.
    return nullptr;
  }
  applyRasterTransform(contentRenderer, plan);

  OpenMask open;
  open.host = host;
  open.handle = handle;
  open.plan = plan;
  open.mode = static_cast<rive::LayerMaskMode>(mode);
  open.contentRenderer = contentRenderer;
  openMasks()[renderer] = open;
  return contentRenderer;
#else
  return nullptr;
#endif
}

// Returns the renderer the mask SOURCE draws through.
EXPORT rive::Renderer* rendererBeginMaskSource(rive::Renderer* renderer)
{
#ifdef RIVE_CANVAS
  auto it = openMasks().find(renderer);
  if (it == openMasks().end())
  {
    return nullptr;
  }
  OpenMask& open = it->second;
  MaskCanvases& canvases = maskCanvases()[open.handle];
  if (canvases.coverage == nullptr)
  {
    return nullptr;
  }
  rive::Renderer* coverageRenderer = open.host->beginCanvasContent(
      canvases.coverage.get(),
      0);
  if (coverageRenderer == nullptr)
  {
    return nullptr;
  }
  applyRasterTransform(coverageRenderer, open.plan);
  open.coverageRenderer = coverageRenderer;
  return coverageRenderer;
#else
  return nullptr;
#endif
}

EXPORT void rendererEndMask(rive::Renderer* renderer)
{
#ifdef RIVE_CANVAS
  auto it = openMasks().find(renderer);
  if (it == openMasks().end())
  {
    return;
  }
  OpenMask open = it->second;
  openMasks().erase(it);

  MaskCanvases& canvases = maskCanvases()[open.handle];
  if (canvases.content == nullptr)
  {
    return;
  }

  if (open.coverageRenderer != nullptr)
  {
    open.coverageRenderer->restore();
    open.host->endCanvasContent(canvases.coverage.get());

    // The mask apply has to be the last draw into the content canvas, and
    // in the canvas's own pixel space: the coverage texture is the same
    // size as the target and has to line up texel for texel, so undo the
    // raster transform that is still in effect.
    if (rive::rcp<rive::RenderImage> coverage = open.host->contentCanvasImage(
            canvases.coverage.get()))
    {
      const float inv = 1.0f / open.plan.rasterScale;
      open.contentRenderer->save();
      open.contentRenderer->translate(
          open.plan.box.left(),
          open.plan.box.top());
      open.contentRenderer->transform(rive::Mat2D::fromScale(inv, inv));
      open.contentRenderer->applyLayerMask(
          coverage.get(),
          rive::ImageSampler::LinearClamp(),
          open.mode);
      open.contentRenderer->restore();
    }
  }

  open.contentRenderer->restore();
  open.host->endCanvasContent(canvases.content.get());

  if (rive::rcp<rive::RenderImage> content = open.host->contentCanvasImage(
          canvases.content.get()))
  {
    auto placement = rive::offscreen::beginComposite(
        renderer,
        open.host,
        open.plan,
        open.plan.rasterScale);
    placement.renderer->drawImage(
        content.get(),
        rive::ImageSampler::LinearClamp(),
        rive::BlendMode::srcOver,
        placement.opacity);
    rive::offscreen::endComposite(placement);
  }
#endif
}
