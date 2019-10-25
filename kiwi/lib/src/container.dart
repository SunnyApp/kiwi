import 'package:kiwi/kiwi.dart';

/// Signature for a builder which creates an object of type [T].
typedef T Factory<T>(Container container);

/// A simple service container.
class Container {
  /// Creates a scoped container.
  Container.scoped() : _namedProviders = Map<String, Map<Type, _Provider<Object>>>();

  static final Container _instance = new Container.scoped();

  /// Always returns a singleton representing the only container to be alive.
  factory Container() => _instance;

  final Map<String, Map<Type, _Provider<Object>>> _namedProviders;

  /// Whether this container has been initialized - which occurs when the first instance has been
  /// requested
  bool _initialized = false;

  /// Whether ignoring assertion errors in the following cases:
  /// * if you register the same type under the same name a second time.
  /// * if you try to resolve or unregister a type that was not
  /// previously registered.
  ///
  /// Defaults to false.
  bool silent = false;

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
    _setProvider(name, _Provider<S>.singleton(factory));
  }

  /// Removes the entry previously registered for the type [T].
  ///
  /// If [name] is set, removes the one registered for that name.
  void unregister<T>([String name]) {
    assert(silent || (_namedProviders[name]?.containsKey(T) ?? false), _assertRegisterMessage<T>('not', name));
    final provider = _namedProviders[name];
    if (provider != null) {
      final instance = provider[T];
      if (instance is LifecycleAware) {
        (instance as LifecycleAware).unregister();
      }
      provider.remove(T);
    }
  }

  /// Attemps to resolve the type [T].
  ///
  /// If [name] is set, the instance or builder registered with this
  /// name will be get.
  ///
  /// See also:
  ///
  ///  * [Container.registerFactory] for register a builder function.
  ///  * [Container.registerInstance] for register an instance.
  T resolve<T>([String name]) {
    if (_initialized != true) {
      _namedProviders.values.forEach((_) {
        _.values.forEach((provider) {
          if (provider.eagerInit == true && provider.object == null) {
            provider.get(this);
          }
        });
      });
      _initialized = true;
    }
    Map<Type, _Provider<Object>> providers = _namedProviders[name];

    assert(silent || (providers?.containsKey(T) ?? false), _assertRegisterMessage<T>('not', name));
    if (providers == null) {
      return null;
    }

    return providers[T]?.get(this);
  }

  T call<T>([String name]) => resolve<T>(name);

  /// Removes all instances and builders from the container.
  ///
  /// After this, the container is empty.
  Future clear() async {
    for (final instances in _namedProviders.values) {
      for (final instance in instances.values) {
        if (instance.object is LifecycleAware) {
          await (instance.object as LifecycleAware).unregister();
        }
      }
    }

    _namedProviders.clear();
  }

  void _setProvider<T>(String name, _Provider<T> provider) {
    assert(
      silent || (!_namedProviders.containsKey(name) || !_namedProviders[name].containsKey(T)),
      _assertRegisterMessage<T>('already', name),
    );

    _namedProviders.putIfAbsent(name, () => Map<Type, _Provider<Object>>())[T] = provider;
  }

  String _assertRegisterMessage<T>(String word, String name) {
    return 'The type $T was $word registered${name == null ? '' : ' for the name $name'}';
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

  _Provider.singleton(this.instanceBuilder, {this.eagerInit = false}) : _oneTime = true;

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
}

abstract class LifecycleAware {
  unregister();
}
