import 'dart:async';

import 'package:logging/logging.dart';

/// Signature for a builder which creates an object of type [T].
typedef T Factory<T>(Container container);

/// A simple service container.
class Container {
  Logger log;

  /// Creates a scoped container.
  Container.scoped([String debugName])
      : _namedProviders = Map<String, Map<Type, _Provider<Object>>>(),
        log = Logger(debugName ?? " kiwi");

  static final Container _instance = new Container.scoped();

  /// Always returns a singleton representing the only container to be alive.
  factory Container({String debugName}) {
    if (debugName != null) {
      _instance.log = Logger(debugName);
    }
    return _instance;
  }

  final Map<String, Map<Type, _Provider<Object>>> _namedProviders;

  final List<Type> _loadingStack = List<Type>();

  /// Whether ignoring assertion errors in the following cases:
  /// * if you register the same type under the same name a second time.
  /// * if you try to resolve or unregister a type that was not
  /// previously registered.
  ///
  /// Defaults to false.
  bool silent = false;

  /// Whether the container is initialized
  bool _isInitialized = false;

  bool get isInitialized {
    return _isInitialized;
  }

  /// Registers an instance into the container.
  ///
  /// An instance of type [T] can be registered with a
  /// supertype [S] if specified.
  ///
  /// If [name] is set, the instance will be registered under this name.
  /// To retrieve the same instance, the same name should be provided
  /// to [Container.resolve].
  void registerInstance<S, T extends S>(
    S instance, {
    String name,
  }) {
    log.fine(
        "Register provider: ${name ?? '[none]'}, type: ${instance.runtimeType}");
    _setProvider(name, _Provider<S>.instance(instance));
  }

  /// Registers a factory into the container.
  ///
  /// A factory returning an object of type [T] can be registered with a
  /// supertype [S] if specified.
  ///
  /// If [name] is set, the factory will be registered under this name.
  /// To retrieve the same factory, the same name should be provided
  /// to [Container.resolve].
  void registerFactory<S, T extends S>(
    Factory<S> factory, {
    String name,
  }) {
    log.fine("Register factory: ${name ?? '[none]'}, type: ${T} for ${S}");
    _setProvider(name, _Provider<S>.factory(factory));
  }

  /// Registers a factory that will be called only only when
  /// accessing it for the first time, into the container.
  ///
  /// A factory returning an object of type [T] can be registered with a
  /// supertype [S] if specified.
  ///
  /// If [name] is set, the factory will be registered under this name.
  /// To retrieve the same factory, the same name should be provided
  /// to [Container.resolve].
  void registerSingleton<S, T extends S>(
    Factory<S> factory, {
    String name,
    bool eagerInit = false,
  }) {
    log.fine("Register singleton: ${name ?? '[none]'}, type: ${T} for ${S}");
    _setProvider(name, _Provider<S>.singleton(factory, eagerInit: eagerInit));
  }

  /// Removes the entry previously registered for the type [T].
  ///
  /// If [name] is set, removes the one registered for that name.
  Future unregister<T>([String name]) async {
    assert(silent || (_namedProviders[name]?.containsKey(T) ?? false),
        _assertRegisterMessage<T>('not', name));
    final provider = _namedProviders[name];
    if (provider != null) {
      final instance = provider[T];
      if (instance is LifecycleAware) {
        await (instance as LifecycleAware)
            .onLifecycleEvent(LifecycleEvent.stop);
        log.fine("Unregister: non-existant $name ($T)");
      } else {
        log.finer("Unregister no lifecycle $name ($T)");
      }
      provider.remove(T);
    } else {
      log.fine("Unregister: non-existant $name ($T)");
    }
  }

  /// Attempts to resolve the type [T].
  ///
  /// If [name] is set, the instance or builder registered with this
  /// name will be get.
  ///
  /// See also:
  ///
  ///  * [Container.registerFactory] for register a builder function.
  ///  * [Container.registerInstance] for register an instance.
  T resolve<T>([String name]) {
    Map<Type, _Provider<Object>> providers = _namedProviders[name];

    assert(silent || (providers?.containsKey(T) ?? false),
        _assertRegisterMessage<T>('not', name));
    if (providers == null) {
      return null;
    }

    if (_loadingStack.contains(T)) {
      throw ("Circular dependency detected between the following: $_loadingStack");
    }
    _loadingStack.add(T);
    final instance = providers[T]?.get(this);
    _loadingStack.removeLast();
    return instance;
  }

  /// Initializes any singletons that are flagged [eagerInit]=true, so you don't have to manually instantiate them.
  Future initializeEagerSingletons() async {
    try {
      log.info("Initializing eager singletons");
      assert(_isInitialized != true);
      for (final _ in _namedProviders.values) {
        for (final provider in _.values) {
          if (provider.eagerInit == true && provider.object == null) {
            final instance = provider.get(this);
            log.fine(
                "\t - Initializing eager singleton: ${instance.runtimeType}, lifecycle: ${instance is LifecycleAware}");
            if (instance is LifecycleAware) {
              await instance.onLifecycleEvent(LifecycleEvent.start);
            }
          }
        }
      }
    } finally {
      _isInitialized = true;
    }
  }

  T call<T>([String name]) => resolve<T>(name);

  void forEachProvider<T>(void onEach(Type type, _Provider provider)) {
    _namedProviders.values.forEach((map) {
      map.forEach(onEach);
    });
  }

  /// Removes all instances and builders from the container.
  ///
  /// After this, the container is empty.
  Future clear() async {
    try {
      int count = 0;
      forEachProvider((_, __) => count++);
      if (count > 0) {
        log.info("Clearing container");
        forEachProvider((type, provider) => log.fine("Clearing $type"));
      }
      final values = [..._namedProviders.values];
      _namedProviders.clear();
      _isInitialized = false;

      for (final instances in values) {
        for (final instance in instances.values) {
          if (instance.object is LifecycleAware) {
            log.fine(
                "\t - Destroying singleton: ${instance.runtimeType}, lifecycle: ${instance.object is LifecycleAware}");
            try {
              await (instance.object as LifecycleAware)
                  .onLifecycleEvent(LifecycleEvent.stop);
            } catch (e) {
              log.severe("Error shutting down ${instance.object}");
              // not going to rethrow because we don't want to mess with other items
            }
          }
        }
      }
    } finally {
      _isInitialized = false;
    }
  }

  void _setProvider<T>(String name, _Provider<T> provider) {
    assert(
      silent ||
          (!_namedProviders.containsKey(name) ||
              !_namedProviders[name].containsKey(T)),
      _assertRegisterMessage<T>('already', name),
    );

    _namedProviders.putIfAbsent(name, () => Map<Type, _Provider<Object>>())[T] =
        provider;
  }

  String _assertRegisterMessage<T>(String word, String name) {
    return 'The type $T was $word registered${name == null ? '' : ' for the name $name'} => $_loadingStack';
  }
}

class _Provider<T> {
  _Provider.instance(this.object)
      : instanceBuilder = null,
        eagerInit = false,
        _oneTime = false;

  _Provider.factory(this.instanceBuilder)
      : eagerInit = false,
        _oneTime = false;

  _Provider.singleton(this.instanceBuilder, {this.eagerInit = false})
      : _oneTime = true;

  final Factory<T> instanceBuilder;
  T object;
  bool _oneTime = false;

  /// Only applies to singletons
  final bool eagerInit;

  T get(Container container) {
    if (_oneTime && instanceBuilder != null) {
      object = instanceBuilder(container);
      _oneTime = false;
    }

    if (object != null) {
      return object;
    }

    if (instanceBuilder != null) {
      return instanceBuilder(container);
    }

    return null;
  }

  @override
  String toString() {
    var str = 'Provider{type: ${T}';
    if (eagerInit == true) str += "; eager = true";
    if (_oneTime == true) str += "; singleton";
    str += "}";
    return str;
  }
}

enum LifecycleEvent { start, stop }

abstract class LifecycleAware {
  FutureOr onLifecycleEvent(LifecycleEvent event);
}

mixin LifecycleAwareMixin implements LifecycleAware {
  FutureOr onInit() {}
  FutureOr onDestroy() {}

  FutureOr onLifecycleEvent(LifecycleEvent event) {
    switch (event) {
      case LifecycleEvent.start:
        return onInit();
      case LifecycleEvent.stop:
        return onDestroy();
    }
  }
}
