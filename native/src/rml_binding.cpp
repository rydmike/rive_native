/*
 * Copyright 2025 Rive
 */

// Markup (.rml) conversion, both directions. Export: the editor already
// builds .rev bytes for backup export; revToRml converts those, in memory,
// into the markup document -- the same conversion rive_rml_generator performs
// on files. Import: rmlToRev compiles a markup document back into .rev bytes,
// which is how the editor turns a committed .rml (its bundled TextInput
// library) into the bytes the library machinery expects.

#include "rive_native/external.hpp"

#include "rive/core/binary_reader.hpp"
#include "rive/core/binary_writer.hpp"
#include "rive/core/vector_binary_writer.hpp"
#include "rive/span.hpp"
#include "rml/embedded_compile_io.hpp"
#include "rml/file_map_compile_io.hpp"
#include "rml/inspect.hpp"
#include "rml/rml.hpp"
#include "rml/sandbox_commit.hpp"
#include "rml/schema.hpp"
#include "src/json_string.hpp"
#include "src/rev_to_core_loader.hpp"
#include "src/core_to_rml_exporter.hpp"

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// The converted document on its way to Dart: malloc'd utf-8 bytes the caller
// copies out and then hands to freeRmlExport.
struct RmlExportResponse
{
#ifdef __EMSCRIPTEN__
  WasmPtr data;
#else
  uint8_t* data;
#endif
  size_t size;
};

// The compiled rev on its way to Dart, or the errors that stopped it: exactly
// one of the two pairs is set. `error` is a utf-8 JSON array of
// {"line", "message", "id"} -- the compiler's own, in the order it reported
// them, then one entry for each file= this converter could not read. Both
// buffers are malloc'd; the caller copies them out and then hands the
// response to freeRmlCompile.
struct RmlCompileResponse
{
#ifdef __EMSCRIPTEN__
  WasmPtr data;
  size_t size;
  WasmPtr error;
  size_t errorSize;
#else
  uint8_t* data;
  size_t size;
  char* error;
  size_t errorSize;
#endif
};

// Copies `size` bytes into a fresh malloc'd buffer the caller frees, and
// reports it through the response's (pointer, size) pair. False leaves the
// pair as it found it: nothing to copy, or nothing to copy into.
template <typename T>
static bool copyOut(const void* source, size_t size, T* data, size_t* outSize)
{
  if (source == nullptr || size == 0)
  {
    return false;
  }
  void* buffer = malloc(size);
  if (buffer == nullptr)
  {
    return false;
  }
  memcpy(buffer, source, size);
  // T is the response's pointer field: a real pointer natively, a WasmPtr
  // under emscripten, where pointers are the 32 bits that cast holds.
  *data = (T)buffer;
  *outSize = size;
  return true;
}

// Converts rev bytes to markup, leaving every payload embedded: an export has
// nowhere to put sibling files, so external-file mode is not offered here.
static bool revToRmlInternal(
    const uint8_t* bytes,
    size_t length,
    RmlExportResponse* response)
{
  if (bytes == nullptr || length == 0 || response == nullptr)
  {
    return false;
  }
  rive::BinaryReader reader(rive::Span<const uint8_t>(bytes, length));
  rive::rml::RevToCoreLoader rev;
  if (!rev.read(reader))
  {
    return false;
  }
  std::string
      rml = rive::rml::CoreToRmlExporter(rev.objects()).writeRmlDocument().rml;
  if (rml.empty())
  {
    return false;
  }
  return copyOut(rml.data(), rml.size(), &response->data, &response->size);
}

static void freeRmlExportInternal(RmlExportResponse* response)
{
  if (response == nullptr || response->data == 0)
  {
    return;
  }
  free(reinterpret_cast<void*>(response->data));
  response->data = 0;
  response->size = 0;
}

// Compiles a markup document into rev bytes. Every payload has to be embedded
// in the document: no AssetPayloads are supplied, and a file= reference has no
// directory to resolve against, so both are reported as errors rather than
// dropped.
static void rmlToRevInternal(
    const uint8_t* bytes,
    size_t length,
    RmlCompileResponse* response)
{
  if (response == nullptr)
  {
    return;
  }
  response->data = 0;
  response->size = 0;
  response->error = 0;
  response->errorSize = 0;
  if (bytes == nullptr || length == 0)
  {
    return;
  }
  rive::rml::EmbeddedCompileIO io;
  auto result = rive::rml::toRev(
      std::string(reinterpret_cast<const char*>(bytes), length),
      io);
  std::vector<rive::rml::Error> errors = io.compileErrors(result);
  if (!errors.empty())
  {
    std::string json = rive::rml::errorsJson(errors);
    copyOut(json.data(), json.size(), &response->error, &response->errorSize);
    return;
  }
  copyOut(io.bytes.data(), io.bytes.size(), &response->data, &response->size);
}

static void freeRmlCompileInternal(RmlCompileResponse* response)
{
  if (response == nullptr)
  {
    return;
  }
  if (response->data != 0)
  {
    free(reinterpret_cast<void*>(response->data));
    response->data = 0;
  }
  if (response->error != 0)
  {
    free(reinterpret_cast<void*>(response->error));
    response->error = 0;
  }
  response->size = 0;
  response->errorSize = 0;
}

// Plain text or JSON on its way to Dart: malloc'd utf-8 bytes the caller
// copies out and then hands to freeRmlSchemaText. data stays 0 for a schema
// search/list result with nothing to say (an empty document, not an error);
// rmlSchemaDescribe additionally uses it to mean "unknown type".
struct RmlSchemaTextResponse
{
#ifdef __EMSCRIPTEN__
  WasmPtr data;
#else
  uint8_t* data;
#endif
  size_t size;
};

// Every core type's schema ships in the binary (core_registry.hpp), unlike
// revToRml/rmlToRev above, which need bytes from the caller: describe/search/
// list read nothing but that table.
static bool rmlSchemaDescribeInternal(
    const uint8_t* typeName,
    size_t typeNameLength,
    bool includeEditorOnly,
    bool animatableOnly,
    bool bindableOnly,
    bool json,
    RmlSchemaTextResponse* response)
{
  if (response == nullptr)
  {
    return false;
  }
  response->data = 0;
  response->size = 0;
  if (typeName == nullptr || typeNameLength == 0)
  {
    return false;
  }
  std::string name(reinterpret_cast<const char*>(typeName), typeNameLength);
  std::string out = json ? rive::rml::schema::describeTypeJson(
                               name,
                               includeEditorOnly,
                               animatableOnly,
                               bindableOnly)
                         : rive::rml::schema::describeTypeText(
                               name,
                               includeEditorOnly,
                               animatableOnly,
                               bindableOnly);
  return copyOut(out.data(), out.size(), &response->data, &response->size);
}

static void rmlSchemaSearchInternal(
    const uint8_t* text,
    size_t textLength,
    bool json,
    RmlSchemaTextResponse* response)
{
  if (response == nullptr)
  {
    return;
  }
  response->data = 0;
  response->size = 0;
  std::string needle = (text != nullptr && textLength > 0)
                           ? std::string(
                                 reinterpret_cast<const char*>(text),
                                 textLength)
                           : std::string();
  std::vector<rive::rml::schema::SchemaMatch>
      matches = rive::rml::schema::searchMatches(needle);
  std::string out = json ? rive::rml::schema::searchMatchesJson(matches)
                         : rive::rml::schema::searchMatchesText(matches);
  copyOut(out.data(), out.size(), &response->data, &response->size);
}

static void rmlSchemaTypesInternal(bool json, RmlSchemaTextResponse* response)
{
  if (response == nullptr)
  {
    return;
  }
  response->data = 0;
  response->size = 0;
  std::vector<std::string> names = rive::rml::schema::typeNames();
  std::string out = json ? rive::rml::schema::typeNamesJson(names)
                         : rive::rml::schema::typeNamesText(names);
  copyOut(out.data(), out.size(), &response->data, &response->size);
}

static void freeRmlSchemaTextInternal(RmlSchemaTextResponse* response)
{
  if (response == nullptr || response->data == 0)
  {
    return;
  }
  free(reinterpret_cast<void*>(response->data));
  response->data = 0;
  response->size = 0;
}

// The inspect problems JSON array on its way to Dart: malloc'd utf-8 bytes
// the caller copies out and then hands to freeRmlInspect. Always at least
// "[]", so data is never 0 for a call that reached copyOut.
struct RmlInspectResponse
{
#ifdef __EMSCRIPTEN__
  WasmPtr data;
#else
  uint8_t* data;
#endif
  size_t size;
};

// Treats `rml` as one document -- no fragments, default InspectOptions --
// the same shape a single .rml file's contents take. Parse failures come
// back as problems (kind "syntax") rather than as a separate error path:
// rive::rml::inspect already folds them in.
static void rmlInspectInternal(
    const uint8_t* rml,
    size_t rmlLength,
    RmlInspectResponse* response)
{
  if (response == nullptr)
  {
    return;
  }
  response->data = 0;
  response->size = 0;
  std::string source = (rml != nullptr && rmlLength > 0)
                           ? std::string(
                                 reinterpret_cast<const char*>(rml),
                                 rmlLength)
                           : std::string();
  rive::rml::InspectResult result = rive::rml::inspect(source);
  std::string out = rive::rml::problemsJson(result.problems);
  copyOut(out.data(), out.size(), &response->data, &response->size);
}

static void freeRmlInspectInternal(RmlInspectResponse* response)
{
  if (response == nullptr || response->data == 0)
  {
    return;
  }
  free(reinterpret_cast<void*>(response->data));
  response->data = 0;
  response->size = 0;
}

// The classified commit diff on its way to Dart: the ChangeSet's wire bytes
// (set only when both documents compile) and the JSON report (always set).
// Both buffers are malloc'd; the caller copies them out and then hands the
// response to freeRmlCommitDiff.
struct RmlCommitDiffResponse
{
#ifdef __EMSCRIPTEN__
  WasmPtr data;
  size_t size;
  WasmPtr report;
  size_t reportSize;
#else
  uint8_t* data;
  size_t size;
  char* report;
  size_t reportSize;
#endif
};

// Null/zero-length input becomes an empty document, mirroring
// rmlInspectInternal's guard.
static std::string toRmlString(const uint8_t* bytes, size_t length)
{
  if (bytes == nullptr || length == 0)
  {
    return std::string();
  }
  return std::string(reinterpret_cast<const char*>(bytes), length);
}

// Compiles base and sandbox and diffs them (rive::rml::diffSandbox). Both
// documents get the same treatment as rmlToRev: every payload has to be
// embedded, so a file= reference is reported rather than resolved.
static void rmlCommitDiffInternal(
    const uint8_t* base,
    size_t baseLength,
    const uint8_t* sandbox,
    size_t sandboxLength,
    uint64_t client,
    uint64_t firstObject,
    RmlCommitDiffResponse* response)
{
  if (response == nullptr)
  {
    return;
  }
  response->data = 0;
  response->size = 0;
  response->report = 0;
  response->reportSize = 0;
  std::string baseRml = toRmlString(base, baseLength);
  std::string sandboxRml = toRmlString(sandbox, sandboxLength);
  rive::codec::CoopId firstNewId{client, firstObject};
  rive::rml::SandboxCommit commit = rive::rml::diffSandbox(
      baseRml,
      sandboxRml,
      firstNewId);
  std::string report = rive::rml::sandboxCommitJson(commit);
  copyOut(
      report.data(),
      report.size(),
      &response->report,
      &response->reportSize);
  if (commit.errors.empty())
  {
    std::vector<uint8_t> bytes;
    commit.changes.serialize(bytes);
    copyOut(bytes.data(), bytes.size(), &response->data, &response->size);
  }
}

static void freeRmlCommitDiffInternal(RmlCommitDiffResponse* response)
{
  if (response == nullptr)
  {
    return;
  }
  if (response->data != 0)
  {
    free(reinterpret_cast<void*>(response->data));
    response->data = 0;
  }
  if (response->report != 0)
  {
    free(reinterpret_cast<void*>(response->report));
    response->report = 0;
  }
  response->size = 0;
  response->reportSize = 0;
}

// The files a project export produced, beside its markup. `data` is the
// markup, `files` the bundle of everything it names with file=. Both buffers
// are malloc'd; the caller copies them out and then hands the response to
// freeRmlExportFiles.
//
// File bundle, both directions: varuint count, then per file a string (varuint
// length + utf-8 path), varuint flags, and bytes (varuint length + bytes).
// flags bit 0 means "withheld" going in -- the file exists, its bytes are not
// supplied -- and "bytes omitted" coming out.
struct RmlExportFilesResponse
{
#ifdef __EMSCRIPTEN__
  WasmPtr data;
  size_t size;
  WasmPtr files;
  size_t filesSize;
#else
  uint8_t* data;
  size_t size;
  uint8_t* files;
  size_t filesSize;
#endif
};

// rmlToRev's response, plus `refs`: a utf-8 JSON array of {"id", "path",
// "line"}, one per file= the markup names. Set whenever the compile ran.
struct RmlProjectCompileResponse
{
#ifdef __EMSCRIPTEN__
  WasmPtr data;
  size_t size;
  WasmPtr error;
  size_t errorSize;
  WasmPtr refs;
  size_t refsSize;
#else
  uint8_t* data;
  size_t size;
  char* error;
  size_t errorSize;
  char* refs;
  size_t refsSize;
#endif
};

static const uint32_t bundleWithheld = 1;

// Fills `io` from a file bundle. False when the bundle is malformed.
static bool readFileBundle(
    const uint8_t* bytes,
    size_t length,
    rive::rml::FileMapCompileIO& io)
{
  if (bytes == nullptr || length == 0)
  {
    return true;
  }
  rive::BinaryReader reader(rive::Span<const uint8_t>(bytes, length));
  uint64_t count = reader.readVarUint64();
  for (uint64_t i = 0; i < count && !reader.hasError(); i++)
  {
    // readBytes bounds the length; readString allocates it first.
    rive::Span<const uint8_t> pathBytes = reader.readBytes();
    std::string path(pathBytes.begin(), pathBytes.end());
    uint64_t flags = reader.readVarUint64();
    rive::Span<const uint8_t> content = reader.readBytes();
    if (reader.hasError())
    {
      break;
    }
    if ((flags & bundleWithheld) != 0)
    {
      io.addWithheld(std::move(path));
    }
    else
    {
      io.add(
          std::move(path),
          std::vector<uint8_t>(content.begin(), content.end()));
    }
  }
  return !reader.hasError() && reader.reachedEnd();
}

static std::string malformedBundleJson()
{
  return rive::rml::errorsJson(
      {rive::rml::Error("the file bundle is malformed", 0)});
}

static void freeRmlExportFilesInternal(RmlExportFilesResponse* response);

static bool revToRmlFilesInternal(
    const uint8_t* bytes,
    size_t length,
    RmlExportFilesResponse* response)
{
  if (response == nullptr)
  {
    return false;
  }
  response->data = 0;
  response->size = 0;
  response->files = 0;
  response->filesSize = 0;
  if (bytes == nullptr || length == 0)
  {
    return false;
  }
  rive::BinaryReader reader(rive::Span<const uint8_t>(bytes, length));
  rive::rml::RevToCoreLoader rev;
  if (!rev.read(reader))
  {
    return false;
  }
  rive::rml::RmlWriteOptions options;
  options.externalFiles = true;
  options.bytelessAssetFiles = true;
  // The editor's RML tools put the markup at main.rml and serve read-only
  // files under builtins/, so no exported file may land on either, nor in
  // a folder that would have to share main.rml's name.
  options.reservedPaths = {"main.rml"};
  options.reservedFolders = {"builtins", "main.rml"};
  rive::rml::RmlDocument document = rive::rml::CoreToRmlExporter(rev.objects())
                                        .writeRmlDocument(options);
  if (document.rml.empty())
  {
    return false;
  }
  std::vector<uint8_t> bundle;
  rive::VectorBinaryWriter writer(&bundle);
  writer.writeVarUint((uint64_t)document.files.size());
  for (const rive::rml::ExternalFile& file : document.files)
  {
    writer.write(file.relPath);
    writer.writeVarUint((uint64_t)(file.bytesOmitted ? bundleWithheld : 0));
    writer.writeVarUint((uint64_t)file.bytes.size());
    writer.write(file.bytes.data(), file.bytes.size());
  }
  if (!copyOut(
          document.rml.data(),
          document.rml.size(),
          &response->data,
          &response->size))
  {
    return false;
  }
  if (!copyOut(
          bundle.data(),
          bundle.size(),
          &response->files,
          &response->filesSize))
  {
    freeRmlExportFilesInternal(response);
    return false;
  }
  return true;
}

static void freeRmlExportFilesInternal(RmlExportFilesResponse* response)
{
  if (response == nullptr)
  {
    return;
  }
  if (response->data != 0)
  {
    free(reinterpret_cast<void*>(response->data));
    response->data = 0;
  }
  if (response->files != 0)
  {
    free(reinterpret_cast<void*>(response->files));
    response->files = 0;
  }
  response->size = 0;
  response->filesSize = 0;
}

static std::string fileReferencesJson(
    const std::vector<rive::rml::FileReference>& references)
{
  std::string out = "[";
  for (size_t i = 0; i < references.size(); i++)
  {
    const rive::rml::FileReference& reference = references[i];
    out += std::string(i == 0 ? "" : ",") +
           "{\"id\":" + rive::rml::jsonString(reference.id) +
           ",\"path\":" + rive::rml::jsonString(reference.path) +
           ",\"line\":" + std::to_string(reference.line) + "}";
  }
  return out + "]";
}

// Compiles a markup document against a project's files: text files are served
// as they are, withheld ones compile without contents. A file the bundle does
// not hold is an error, as is a script reading a withheld one.
static void rmlToRevFilesInternal(
    const uint8_t* bytes,
    size_t length,
    const uint8_t* files,
    size_t filesLength,
    RmlProjectCompileResponse* response)
{
  if (response == nullptr)
  {
    return;
  }
  response->data = 0;
  response->size = 0;
  response->error = 0;
  response->errorSize = 0;
  response->refs = 0;
  response->refsSize = 0;
  if (bytes == nullptr || length == 0)
  {
    return;
  }
  rive::rml::FileMapCompileIO io;
  if (!readFileBundle(files, filesLength, io))
  {
    std::string json = malformedBundleJson();
    copyOut(json.data(), json.size(), &response->error, &response->errorSize);
    return;
  }
  auto result = rive::rml::toRev(
      std::string(reinterpret_cast<const char*>(bytes), length),
      io);
  std::string refs = fileReferencesJson(result.fileReferences);
  copyOut(refs.data(), refs.size(), &response->refs, &response->refsSize);
  std::vector<rive::rml::Error> errors = io.compileErrors(result);
  if (!errors.empty())
  {
    std::string json = rive::rml::errorsJson(errors);
    copyOut(json.data(), json.size(), &response->error, &response->errorSize);
    return;
  }
  copyOut(io.bytes.data(), io.bytes.size(), &response->data, &response->size);
}

static void freeRmlProjectCompileInternal(RmlProjectCompileResponse* response)
{
  if (response == nullptr)
  {
    return;
  }
  if (response->data != 0)
  {
    free(reinterpret_cast<void*>(response->data));
    response->data = 0;
  }
  if (response->error != 0)
  {
    free(reinterpret_cast<void*>(response->error));
    response->error = 0;
  }
  if (response->refs != 0)
  {
    free(reinterpret_cast<void*>(response->refs));
    response->refs = 0;
  }
  response->size = 0;
  response->errorSize = 0;
  response->refsSize = 0;
}

// rmlCommitDiff over projects: each document compiles against its own files.
static void rmlCommitDiffFilesInternal(
    const uint8_t* base,
    size_t baseLength,
    const uint8_t* baseFiles,
    size_t baseFilesLength,
    const uint8_t* sandbox,
    size_t sandboxLength,
    const uint8_t* sandboxFiles,
    size_t sandboxFilesLength,
    uint64_t client,
    uint64_t firstObject,
    RmlCommitDiffResponse* response)
{
  if (response == nullptr)
  {
    return;
  }
  response->data = 0;
  response->size = 0;
  response->report = 0;
  response->reportSize = 0;
  rive::rml::FileMapCompileIO baseIO;
  rive::rml::FileMapCompileIO sandboxIO;
  rive::rml::SandboxCommit commit;
  bool baseOk = readFileBundle(baseFiles, baseFilesLength, baseIO);
  bool sandboxOk = readFileBundle(sandboxFiles, sandboxFilesLength, sandboxIO);
  if (!baseOk || !sandboxOk)
  {
    commit.baseFailed = !baseOk;
    if (!baseOk)
    {
      commit.errors.push_back(
          rive::rml::Error("the base file bundle is malformed", 0));
    }
    if (!sandboxOk)
    {
      commit.errors.push_back(
          rive::rml::Error("the sandbox file bundle is malformed", 0));
    }
  }
  else
  {
    commit = rive::rml::diffSandbox(
        toRmlString(base, baseLength),
        baseIO,
        toRmlString(sandbox, sandboxLength),
        sandboxIO,
        rive::codec::CoopId{client, firstObject});
  }
  std::string report = rive::rml::sandboxCommitJson(commit);
  copyOut(
      report.data(),
      report.size(),
      &response->report,
      &response->reportSize);
  if (commit.errors.empty())
  {
    std::vector<uint8_t> bytes;
    commit.changes.serialize(bytes);
    copyOut(bytes.data(), bytes.size(), &response->data, &response->size);
  }
}

#ifndef __EMSCRIPTEN__
EXPORT bool revToRml(
    const uint8_t* bytes,
    SizeType length,
    RmlExportResponse* response)
{
  return revToRmlInternal(bytes, (size_t)length, response);
}

EXPORT void freeRmlExport(RmlExportResponse* response)
{
  freeRmlExportInternal(response);
}

EXPORT void rmlToRev(
    const uint8_t* bytes,
    SizeType length,
    RmlCompileResponse* response)
{
  rmlToRevInternal(bytes, (size_t)length, response);
}

EXPORT void freeRmlCompile(RmlCompileResponse* response)
{
  freeRmlCompileInternal(response);
}

EXPORT bool rmlSchemaDescribe(
    const uint8_t* typeName,
    SizeType typeNameLength,
    bool includeEditorOnly,
    bool animatableOnly,
    bool bindableOnly,
    bool json,
    RmlSchemaTextResponse* response)
{
  return rmlSchemaDescribeInternal(
      typeName,
      (size_t)typeNameLength,
      includeEditorOnly,
      animatableOnly,
      bindableOnly,
      json,
      response);
}

EXPORT void rmlSchemaSearch(
    const uint8_t* text,
    SizeType textLength,
    bool json,
    RmlSchemaTextResponse* response)
{
  rmlSchemaSearchInternal(text, (size_t)textLength, json, response);
}

EXPORT void rmlSchemaTypes(bool json, RmlSchemaTextResponse* response)
{
  rmlSchemaTypesInternal(json, response);
}

EXPORT void freeRmlSchemaText(RmlSchemaTextResponse* response)
{
  freeRmlSchemaTextInternal(response);
}

EXPORT void rmlInspect(
    const uint8_t* rml,
    SizeType rmlLength,
    RmlInspectResponse* response)
{
  rmlInspectInternal(rml, (size_t)rmlLength, response);
}

EXPORT void freeRmlInspect(RmlInspectResponse* response)
{
  freeRmlInspectInternal(response);
}

EXPORT void rmlCommitDiff(
    const uint8_t* base,
    SizeType baseLength,
    const uint8_t* sandbox,
    SizeType sandboxLength,
    uint64_t client,
    uint64_t firstObject,
    RmlCommitDiffResponse* response)
{
  rmlCommitDiffInternal(
      base,
      (size_t)baseLength,
      sandbox,
      (size_t)sandboxLength,
      client,
      firstObject,
      response);
}

EXPORT void freeRmlCommitDiff(RmlCommitDiffResponse* response)
{
  freeRmlCommitDiffInternal(response);
}

EXPORT bool revToRmlFiles(
    const uint8_t* bytes,
    SizeType length,
    RmlExportFilesResponse* response)
{
  return revToRmlFilesInternal(bytes, (size_t)length, response);
}

EXPORT void freeRmlExportFiles(RmlExportFilesResponse* response)
{
  freeRmlExportFilesInternal(response);
}

EXPORT void rmlToRevFiles(
    const uint8_t* bytes,
    SizeType length,
    const uint8_t* files,
    SizeType filesLength,
    RmlProjectCompileResponse* response)
{
  rmlToRevFilesInternal(
      bytes,
      (size_t)length,
      files,
      (size_t)filesLength,
      response);
}

EXPORT void freeRmlProjectCompile(RmlProjectCompileResponse* response)
{
  freeRmlProjectCompileInternal(response);
}

EXPORT void rmlCommitDiffFiles(
    const uint8_t* base,
    SizeType baseLength,
    const uint8_t* baseFiles,
    SizeType baseFilesLength,
    const uint8_t* sandbox,
    SizeType sandboxLength,
    const uint8_t* sandboxFiles,
    SizeType sandboxFilesLength,
    uint64_t client,
    uint64_t firstObject,
    RmlCommitDiffResponse* response)
{
  rmlCommitDiffFilesInternal(
      base,
      (size_t)baseLength,
      baseFiles,
      (size_t)baseFilesLength,
      sandbox,
      (size_t)sandboxLength,
      sandboxFiles,
      (size_t)sandboxFilesLength,
      client,
      firstObject,
      response);
}
#endif

#ifdef __EMSCRIPTEN__
#include <emscripten/bind.h>

static RmlExportResponse revToRmlWasm(WasmPtr bufferPtr, WasmPtr length)
{
  RmlExportResponse response = {0, 0};
  revToRmlInternal((const uint8_t*)bufferPtr, (size_t)length, &response);
  return response;
}

static void freeRmlExportWasm(RmlExportResponse response)
{
  freeRmlExportInternal(&response);
}

static RmlCompileResponse rmlToRevWasm(WasmPtr bufferPtr, WasmPtr length)
{
  RmlCompileResponse response = {0, 0, 0, 0};
  rmlToRevInternal((const uint8_t*)bufferPtr, (size_t)length, &response);
  return response;
}

static void freeRmlCompileWasm(RmlCompileResponse response)
{
  freeRmlCompileInternal(&response);
}

static RmlSchemaTextResponse rmlSchemaDescribeWasm(
    WasmPtr typeNamePtr,
    WasmPtr typeNameLength,
    bool includeEditorOnly,
    bool animatableOnly,
    bool bindableOnly,
    bool json)
{
  RmlSchemaTextResponse response = {0, 0};
  rmlSchemaDescribeInternal(
      (const uint8_t*)typeNamePtr,
      (size_t)typeNameLength,
      includeEditorOnly,
      animatableOnly,
      bindableOnly,
      json,
      &response);
  return response;
}

static RmlSchemaTextResponse rmlSchemaSearchWasm(
    WasmPtr textPtr,
    WasmPtr textLength,
    bool json)
{
  RmlSchemaTextResponse response = {0, 0};
  rmlSchemaSearchInternal(
      (const uint8_t*)textPtr,
      (size_t)textLength,
      json,
      &response);
  return response;
}

static RmlSchemaTextResponse rmlSchemaTypesWasm(bool json)
{
  RmlSchemaTextResponse response = {0, 0};
  rmlSchemaTypesInternal(json, &response);
  return response;
}

static void freeRmlSchemaTextWasm(RmlSchemaTextResponse response)
{
  freeRmlSchemaTextInternal(&response);
}

static RmlInspectResponse rmlInspectWasm(WasmPtr rmlPtr, WasmPtr rmlLength)
{
  RmlInspectResponse response = {0, 0};
  rmlInspectInternal((const uint8_t*)rmlPtr, (size_t)rmlLength, &response);
  return response;
}

static void freeRmlInspectWasm(RmlInspectResponse response)
{
  freeRmlInspectInternal(&response);
}

// double, not WasmPtr: ids need to stay exact up to 2^53 without BigInt.
static RmlCommitDiffResponse rmlCommitDiffWasm(
    WasmPtr basePtr,
    WasmPtr baseLength,
    WasmPtr sandboxPtr,
    WasmPtr sandboxLength,
    double client,
    double firstObject)
{
  RmlCommitDiffResponse response = {0, 0, 0, 0};
  rmlCommitDiffInternal(
      (const uint8_t*)basePtr,
      (size_t)baseLength,
      (const uint8_t*)sandboxPtr,
      (size_t)sandboxLength,
      (uint64_t)client,
      (uint64_t)firstObject,
      &response);
  return response;
}

static void freeRmlCommitDiffWasm(RmlCommitDiffResponse response)
{
  freeRmlCommitDiffInternal(&response);
}

static RmlExportFilesResponse revToRmlFilesWasm(
    WasmPtr bufferPtr,
    WasmPtr length)
{
  RmlExportFilesResponse response = {0, 0, 0, 0};
  revToRmlFilesInternal((const uint8_t*)bufferPtr, (size_t)length, &response);
  return response;
}

static void freeRmlExportFilesWasm(RmlExportFilesResponse response)
{
  freeRmlExportFilesInternal(&response);
}

static RmlProjectCompileResponse rmlToRevFilesWasm(
    WasmPtr bufferPtr,
    WasmPtr length,
    WasmPtr filesPtr,
    WasmPtr filesLength)
{
  RmlProjectCompileResponse response = {0, 0, 0, 0, 0, 0};
  rmlToRevFilesInternal(
      (const uint8_t*)bufferPtr,
      (size_t)length,
      (const uint8_t*)filesPtr,
      (size_t)filesLength,
      &response);
  return response;
}

static void freeRmlProjectCompileWasm(RmlProjectCompileResponse response)
{
  freeRmlProjectCompileInternal(&response);
}

// double, not WasmPtr, for the ids, as rmlCommitDiffWasm.
static RmlCommitDiffResponse rmlCommitDiffFilesWasm(
    WasmPtr basePtr,
    WasmPtr baseLength,
    WasmPtr baseFilesPtr,
    WasmPtr baseFilesLength,
    WasmPtr sandboxPtr,
    WasmPtr sandboxLength,
    WasmPtr sandboxFilesPtr,
    WasmPtr sandboxFilesLength,
    double client,
    double firstObject)
{
  RmlCommitDiffResponse response = {0, 0, 0, 0};
  rmlCommitDiffFilesInternal(
      (const uint8_t*)basePtr,
      (size_t)baseLength,
      (const uint8_t*)baseFilesPtr,
      (size_t)baseFilesLength,
      (const uint8_t*)sandboxPtr,
      (size_t)sandboxLength,
      (const uint8_t*)sandboxFilesPtr,
      (size_t)sandboxFilesLength,
      (uint64_t)client,
      (uint64_t)firstObject,
      &response);
  return response;
}

EMSCRIPTEN_BINDINGS(RiveRml)
{
  emscripten::value_object<RmlExportResponse>("RmlExportResponse")
      .field("data", &RmlExportResponse::data)
      .field("size", &RmlExportResponse::size);
  emscripten::function("revToRmlWasm", &revToRmlWasm);
  emscripten::function("freeRmlExportWasm", &freeRmlExportWasm);

  emscripten::value_object<RmlCompileResponse>("RmlCompileResponse")
      .field("data", &RmlCompileResponse::data)
      .field("size", &RmlCompileResponse::size)
      .field("error", &RmlCompileResponse::error)
      .field("errorSize", &RmlCompileResponse::errorSize);
  emscripten::function("rmlToRevWasm", &rmlToRevWasm);
  emscripten::function("freeRmlCompileWasm", &freeRmlCompileWasm);

  emscripten::value_object<RmlSchemaTextResponse>("RmlSchemaTextResponse")
      .field("data", &RmlSchemaTextResponse::data)
      .field("size", &RmlSchemaTextResponse::size);
  emscripten::function("rmlSchemaDescribeWasm", &rmlSchemaDescribeWasm);
  emscripten::function("rmlSchemaSearchWasm", &rmlSchemaSearchWasm);
  emscripten::function("rmlSchemaTypesWasm", &rmlSchemaTypesWasm);
  emscripten::function("freeRmlSchemaTextWasm", &freeRmlSchemaTextWasm);

  emscripten::value_object<RmlInspectResponse>("RmlInspectResponse")
      .field("data", &RmlInspectResponse::data)
      .field("size", &RmlInspectResponse::size);
  emscripten::function("rmlInspectWasm", &rmlInspectWasm);
  emscripten::function("freeRmlInspectWasm", &freeRmlInspectWasm);

  emscripten::value_object<RmlCommitDiffResponse>("RmlCommitDiffResponse")
      .field("data", &RmlCommitDiffResponse::data)
      .field("size", &RmlCommitDiffResponse::size)
      .field("report", &RmlCommitDiffResponse::report)
      .field("reportSize", &RmlCommitDiffResponse::reportSize);
  emscripten::function("rmlCommitDiffWasm", &rmlCommitDiffWasm);
  emscripten::function("freeRmlCommitDiffWasm", &freeRmlCommitDiffWasm);

  emscripten::value_object<RmlExportFilesResponse>("RmlExportFilesResponse")
      .field("data", &RmlExportFilesResponse::data)
      .field("size", &RmlExportFilesResponse::size)
      .field("files", &RmlExportFilesResponse::files)
      .field("filesSize", &RmlExportFilesResponse::filesSize);
  emscripten::function("revToRmlFilesWasm", &revToRmlFilesWasm);
  emscripten::function("freeRmlExportFilesWasm", &freeRmlExportFilesWasm);

  emscripten::value_object<RmlProjectCompileResponse>(
      "RmlProjectCompileResponse")
      .field("data", &RmlProjectCompileResponse::data)
      .field("size", &RmlProjectCompileResponse::size)
      .field("error", &RmlProjectCompileResponse::error)
      .field("errorSize", &RmlProjectCompileResponse::errorSize)
      .field("refs", &RmlProjectCompileResponse::refs)
      .field("refsSize", &RmlProjectCompileResponse::refsSize);
  emscripten::function("rmlToRevFilesWasm", &rmlToRevFilesWasm);
  emscripten::function("freeRmlProjectCompileWasm", &freeRmlProjectCompileWasm);

  emscripten::function("rmlCommitDiffFilesWasm", &rmlCommitDiffFilesWasm);
}
#endif
