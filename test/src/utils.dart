/// Platform-conditional test utilities.
///
/// On the VM (`flutter test`) files are read straight from disk; in the
/// browser (`flutter test --platform chrome`) they are fetched from a local
/// static server. See `utils_web.dart` for the server setup.
library;

import 'package:rive_native/rive_native.dart';

export 'utils_io.dart' if (dart.library.js_interop) 'utils_web.dart';

/// Creates a default instance of the view model named [name], releasing the
/// intermediate [ViewModel] wrapper.
BindableViewModelInstance makeDefaultInstance(File file, String name) {
  final viewModel = file.viewModelByName(name)!;
  try {
    return viewModel.createDefaultInstance()!;
  } finally {
    viewModel.dispose();
  }
}
