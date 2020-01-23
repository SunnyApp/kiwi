import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

/// Signature for a builder which creates an object of type [T].
typedef T Factory<T>(Container container);

/// A simple service container.
class Container {
  Logger log;

  /// Creates a scoped container.
  Container.scoped([String debugName])
      : _namedProviders = Map<String, Map<Type, _Provider<Object>>>(),
        log = Logger(debugName ?? "kiwi");

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
  ContainerState _state = ContainerState.Building;

  bool get isInitialized {
    return _state == ContainerState.Ready;
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
    log.fine("Register provider: ${name ?? '[none]'}, type: ${instance.runtimeType}");
    _setProvider(name, _Provider<S>.instance(Instance(instance)));
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
    assert(silent || (_namedProviders[name]?.containsKey(T) ?? false), _assertRegisterMessage<T>('not', name));
    final namedProvider = _namedProviders[name];
    if (namedProvider != null) {
      final provider = namedProvider[T];
      if (provider?.object?.value is LifecycleAware) {
        await (provider.object?.value as LifecycleAware).onLifecycleEvent(LifecycleEvent.stop);
        log.fine("Unregister: non-existant $name ($T)");
      } else {
        log.finer("Unregister no lifecycle $name ($T)");
      }
      namedProvider.remove(T);
    } else {
      log.fine("Unregister: non-existant $name ($T)");
    }
  }

  Instance<T> instance<T>([String name]) {
    Map<Type, _Provider<Object>> providers = _namedProviders[name];
    if (!silent && !(providers?.containsKey(T) ?? false)) {
      throw "No component registered for $T ${name == null ? '' : "name=$name"}";
    }
    if (providers == null) {
      return null;
    }

    final indexOf = _loadingStack.indexOf(T);
    if (indexOf > -1 && indexOf < _loadingStack.length - 1) {
      throw ("Circular dependency detected between the following: $_loadingStack - when loading $T");
    }

    _loadingStack.add(T);
    final instance = providers[T]?.get(this);
    _loadingStack.removeLast();
    return instance;
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
    return instance<T>(name).value;
  }

  /// Initializes any singletons that are flagged [eagerInit]=true, so you don't have to manually instantiate them.
  Future initializeEagerSingletons() async {
    // This means we're initializing twice.
    assert(_state != ContainerState.Initializing, "Already initializing");

    _state = ContainerState.Initializing;
    try {
      await _initializeEagerSingletons();
      _state = ContainerState.Ready;
    } catch (e) {
      _state = ContainerState.Error;
    }
  }

  Future _initializeEagerSingletons() async {
    try {
      log.info("Initializing eager singletons:");
      if (log.isLoggable(Level.INFO)) {
        for (final provider in _providers) {
          if (provider.eagerInit == true) {
            if (provider.object == null) {
              log.info("  - $provider");
            } else {
              log.info("  - $provider (skipping)");
            }
          }
        }
      }

      await Future.wait(
          _providers.where((provider) => provider.eagerInit == true && provider.object == null).map((provider) {
            final instance = provider.get(this);
            log.fine(
                "\t - Initializing eager singleton: ${instance.runtimeType}, lifecycle: ${instance.value is LifecycleAware}");
            return instance.ready.timeout(Duration(seconds: 10));
          }),
          eagerError: true);
      log.info("\t - ** Done initializing singletons");
    } catch (e, stack) {
      log.severe("Error loading: $e", e, stack);
      print("############################################################");
      print("Error! $e");
      print("############################################################");
      rethrow;
    }
  }

  T call<T>([String name]) => resolve<T>(name);

  void forEachProvider<T>(void onEach(Type type, _Provider provider)) {
    _namedProviders.values.forEach((map) {
      map.forEach(onEach);
    });
  }

  List<_Provider> get _providers {
    final _ = <_Provider>[];
    _namedProviders.values.forEach((map) {
      _.addAll(map.values);
    });
    return _;
  }

  /// Removes all instances and builders from the container.
  ///
  /// After this, the container is empty.
  Future clear() async {
    int count = 0;
    forEachProvider((_, __) => count++);
    if (count > 0) {
      log.info("Clearing container");
      forEachProvider((type, provider) => log.fine("Clearing $type"));
    }
    final values = [..._namedProviders.values];
    _namedProviders.clear();
    _state = ContainerState.Destroying;

    for (final instances in values) {
      for (final instance in instances.values) {
        if (instance.object is LifecycleAware) {
          log.fine(
              "\t - Destroying singleton: ${instance.runtimeType}, lifecycle: ${instance.object is LifecycleAware}");
          try {
            await (instance.object as LifecycleAware).onLifecycleEvent(LifecycleEvent.stop);
          } catch (e) {
            log.severe("Error shutting down ${instance.object}");
            // not going to rethrow because we don't want to mess with other providers
          }
        }
      }
    }
    _state = ContainerState.Building;
  }

  void _setProvider<T>(String name, _Provider<T> provider) {
    assert(
      silent || (!_namedProviders.containsKey(name) || !_namedProviders[name].containsKey(T)),
      _assertRegisterMessage<T>('already', name),
    );

    _namedProviders.putIfAbsent(name, () => Map<Type, _Provider<Object>>())[T] = provider;
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

  _Provider.singleton(this.instanceBuilder, {this.eagerInit = false}) : _oneTime = true;

  final Factory<T> instanceBuilder;
  Instance<T> object;
  bool _oneTime = false;

  /// Only applies to singletons
  final bool eagerInit;

  Instance<T> get(Container container) {
    if (_oneTime && instanceBuilder != null) {
      final inst = instanceBuilder(container);
      if (inst is LifecycleAware) {
        object = Instance(inst, init: (inst).onLifecycleEvent(LifecycleEvent.start));
      } else {
        object = Instance(inst);
      }
      _oneTime = false;
    }

    if (object != null) {
      return object;
    }

    if (instanceBuilder != null) {
      final inst = instanceBuilder(container);
      if (inst is LifecycleAware) {
        return Instance(inst, init: inst.onLifecycleEvent(LifecycleEvent.start));
      } else {
        return Instance(inst);
      }
    }

    return null;
  }

  @override
  String toString() {
    var str = '${T} { ';
    if (eagerInit == true) str += "eager, ";
    if (_oneTime == true) {
      str += "singleton, ${object == null ? 'uninitialized ' : 'initialized '}";
    } else {
      str += "prototype ";
    }

    str += "}";
    return str;
  }
}

class Instance<T> {
  final T value;
  final Completer<T> _completer;

  Instance(this.value, {Future init}) : _completer = Completer() {
    if (init == null) {
      if (!_completer.isCompleted) {
        _completer.complete(value);
      }
    } else {
      init.then((_) {
        if (!_completer.isCompleted) _completer.complete(value);
      });
    }
  }

  Future<T> get ready => _completer.future;
}

enum LifecycleEvent { start, stop }

abstract class LifecycleAware {
  String get instanceId;

  FutureOr onLifecycleEvent(LifecycleEvent event);
}

typedef LifecycleCallback<T> = FutureOr<T> Function();

/// Lifecycle mixin that provides convenience hooks for registering cancellables, like timers, streams, etc.
mixin LifecycleAwareMixin implements LifecycleAware {
  Logger get log;
  String _instanceId;
  String get instanceId => _instanceId ??= Uuid().v4();

  /// A helpful flag that allows us to ensure that mixins that participate in the lifecycle have been set up
  /// properly... sometimes, they may require that a registration hook has been invoked in the constructor,
  /// so checking this variable ensures that things have been set up properly.
  ///
  /// By default, [hasBeenInitialized] returns true
  bool get hasBeenInitialized => true;

  final _onInit = <String, LifecycleCallback>{};
  final _onDestroy = <String, LifecycleCallback>{};

  void onInit(String name, LifecycleCallback init, {Duration wait}) {
    if (_onInit.containsKey(name)) {
      throw "Initializer $name already exists for $runtimeType";
    }
    if (wait != null) {
      _onInit[name] = () {
        // Don't return this value because we dont' want to block startup
        Future.delayed(wait, init);
      };
    } else {
      _onInit[name] = init;
    }
  }

  void onDestroy(String name, LifecycleCallback destroy, {Duration wait}) {
    if (_onDestroy.containsKey(name)) {
      throw "Initializer $name already exists for $runtimeType";
    }
    if (wait != null) {
      _onDestroy[name] = () {
        // Don't return this value because we dont' want to block startup
        Future.delayed(wait, destroy);
      };
    } else {
      _onDestroy[name] = destroy;
    }
  }

  void autoTimer(String name, LifecycleCallback<Timer> generate) {
    onInit(name, () async {
      final timer = await generate();

      onDestroy(name, () async {
        timer.cancel();
      });
    });
  }

  Future autoSubscribe(String name, LifecycleCallback<StreamSubscription> generate) async {
    onInit(name, () async {
      final subscribe = await generate();

      onDestroy(name, () async {
        await subscribe.cancel();
      });
    });
  }

  Future autoStream<T>(String name, LifecycleCallback<Stream<T>> stream, {bool cancelOnError = false}) async {
    onInit(name, () async {
      final subscribe = (await stream()).listen((_) {}, cancelOnError: false);

      onDestroy(name, () async {
        await subscribe.cancel();
      });
    });
  }

  @mustCallSuper
  FutureOr onLifecycleEvent(LifecycleEvent event) async {
    assert(
        this.hasBeenInitialized == true,
        "$runtimeType has not been initialized.  There is probably a registration hook that needs to be called in "
        "the constructor (synchronously)");
    final errors = <String, dynamic>{};
    switch (event) {
      case LifecycleEvent.start:
        for (final _ in _onInit.entries) {
          final init = _.value;
          try {
            log.info("  - initializer[${_.key}]");
            await init();
          } catch (e, stack) {
            log.severe("  - initializer[${_.key}]: $e", e, stack);
            errors[_.key] = [e, stack];
          }
        }
        break;
      case LifecycleEvent.stop:
        for (final _ in _onDestroy.entries) {
          final destroy = _.value;
          try {
            log.info("  - destroy[${_.key}]");
            await destroy();
          } catch (e, stack) {
            log.severe("  - destroy[${_.key}]: $e", e, stack);
            errors[_.key] = [e, stack];
          }
        }
        break;
    }

    if (errors.isNotEmpty) {
      throw LifecycleException(errors);
    }
  }
}

enum ContainerState { Building, Initializing, Ready, Destroying, Error }

class LifecycleException {
  final Map<String, dynamic> errors;

  LifecycleException(this.errors);

  @override
  String toString() {
    return 'LifecycleException{$errors}';
  }
}
