import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

final _log = Logger("factory");

/// Signature for a builder which creates an object of type [T].
typedef Factory<T> = T Function(Container container);

/// A simple service container.
class Container {
  Logger log;

  /// Creates a scoped container.
  Container.scoped([String debugName])
      : _namedProviders = <String, Map<String, _Provider>>{},
        log = Logger(debugName ?? "kiwi");

  static final Container _instance = Container.scoped();

  /// Always returns a singleton representing the only container to be alive.
  factory Container({String debugName}) {
    if (debugName != null) {
      _instance.log = Logger(debugName);
    }
    return _instance;
  }

  final Map<String, Map<String, _Provider>> _namedProviders;

  final List<String> _loadingStack = <String>[];

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
    T instance, {
    String name,
    bool isSilent,
  }) {
    Type registeredType = S;
    if (registeredType == dynamic) registeredType = T;
    if (registeredType == dynamic) {
      throw "Invalid registration.  The type variables S and T cannot be dynamic, but "
          "were $S and $T, respectively";
    }
    log.fine("Register provider: ${name ?? '[none]'}, type: $registeredType");
    _setProvider(
        name, _Provider.instance(Instance(instance), "$registeredType"),
        isSilent: isSilent);
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
    bool isSilent,
  }) {
    Type registeredType = S;
    if (registeredType == dynamic) registeredType = T;
    if (registeredType == dynamic) {
      throw "Invalid registration.  The type variables S and T cannot be dynamic, but "
          "were $S and $T, respectively";
    }
    log.fine("Register factory: ${name ?? '[none]'}, type: $T for $S");
    _setProvider(name, _Provider.factory(factory, "$S"), isSilent: isSilent);
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
    bool isSilent,
  }) {
    if (S == dynamic || T == dynamic) {
      throw 'Invalid registration.  The type variables S and T cannot be dynamic, but '
          'were $S and $T, respectively';
    }
    log.fine("Register singleton: ${name ?? '[none]'}, type: $T for $S");
    _setProvider(
      name,
      _Provider.singleton(factory, type: "$S", eagerInit: eagerInit),
      isSilent: isSilent,
    );
  }

  /// Removes the entry previously registered for the type [T].
  ///
  /// If [name] is set, removes the one registered for that name.
  Future unregister<T>({String name, bool isSilent}) async {
    isSilent ??= silent;
    final typeName = '$T';
    assert(isSilent || (_namedProviders[name]?.containsKey(typeName) ?? false),
        _assertRegisterMessage('not', name, typeName));
    final namedProvider = _namedProviders[name];
    if (namedProvider != null) {
      final provider = namedProvider[typeName];
      if (provider?.object?.value is LifecycleAware) {
        await (provider.object?.value as LifecycleAware)
            .onLifecycleEvent(LifecycleEvent.stop);
        log.fine('Unregister: non-existant $name ($typeName)');
      } else {
        log.finer('Unregister no lifecycle $name ($typeName)');
      }
      namedProvider.remove(typeName);
    } else {
      log.fine('Unregister: non-existant $name ($typeName)');
    }
  }

  Instance instance<T>({
    String name,

    /// Will look for any already created instances that implement the provided type
    bool autoRegister = false,
  }) {
    final resolved = tryInstance<T>(name: name, autoRegister: autoRegister);
    if (!silent && resolved == null) {
      final typeName = '$T';
      throw AssertionError(
          "No component registered for $typeName ${name == null ? '' : "name=$name"}");
    }
    return resolved;
  }

  Instance tryInstance<T>(
      {String name,

      /// Will look for any already created instances that implement the provided type
      bool autoRegister = false}) {
    final typeName = '$T';
    // ignore: omit_local_variable_types
    Map<String, _Provider> providers = _namedProviders[name];
    if (!(providers?.containsKey(typeName) ?? false)) {
      T res;
      if (autoRegister) {
        res = searchForImplementation<T>(name);
      }
      return res == null ? null : Instance(res);
    }
    if (providers == null) {
      return null;
    }

    final indexOf = _loadingStack.indexOf(typeName);
    if (indexOf > -1 && indexOf < _loadingStack.length - 1) {
      throw ('Circular dependency detected between the following: $_loadingStack - when loading $typeName');
    }

    _loadingStack.add(typeName);
    final instance = providers[typeName]?.get(this);
    _loadingStack.removeLast();
    return instance;
  }

  /// Searches existing instances that have been previously registered to find
  /// one that implements [T]
  T searchForImplementation<T>([String name]) {
    if (!silent) {
      log.fine(
          "Doing a type-based lookup for type $T because no registered implementation.  "
          "To speed this up, you should register this entity manually at startup");
    }
    final provider = _namedProviders.values.expand((e) => e.values).firstWhere(
        (provider) => provider.object?.value is T,
        orElse: () => null);

    if (provider != null) {
      /// register this instance against the prior type
      var found = provider.object.value as T;
      log.info(
          "Found unregistered match of ${found.runtimeType} for requested $T");
      registerInstance<T, T>(found);
      return found;
    }

    log.info("No match could be found by type matching $T");
    return null;
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
  T call<T>([String name]) => resolve<T>(name: name);

  T resolve<T>({String name, bool autoRegister = false}) {
    if ("$T" == "$dynamic") {
      throw 'Cannot request type dynamic';
    }
    final result = instance<T>(name: name, autoRegister: autoRegister)?.value;
    if (result != null && result is! T) {
      throw "Invalid container result.  Expected $T but got ${result.runtimeType ?? 'null'}";
    }
    return result as T;
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
          _providers
              .where((provider) =>
                  provider.eagerInit == true && provider.object == null)
              .map((provider) async {
            try {
              final instance = provider.get(this);
              log.fine(
                  "\t - Initializing eager singleton: ${provider.type}, lifecycle: ${instance.value is LifecycleAware}");
              return await instance.ready.timeout(Duration(seconds: 10));
            } catch (e, stack) {
              log.severe("Error loading ${provider.type}", e, stack);
              rethrow;
            }
          }),
          eagerError: true);
      log.info("\t - ** Done initializing singletons");
    } catch (e, stack) {
      log.severe("Error loading: $e", e, stack);
      print("############################################################");
      print("Error! $e");
      print(stack);
      print("############################################################");
      rethrow;
    }
  }

  void forEachProvider(void onEach(String type, _Provider provider)) {
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
            await (instance.object as LifecycleAware)
                .onLifecycleEvent(LifecycleEvent.stop);
          } catch (e) {
            log.severe("Error shutting down ${instance.object}");
            // not going to rethrow because we don't want to mess with other providers
          }
        }
      }
    }
    _state = ContainerState.Building;
  }

  void _setProvider(String name, _Provider provider, {bool isSilent}) {
    isSilent ??= silent;
    assert(
      isSilent ||
          (!_namedProviders.containsKey(name) ||
              !_namedProviders[name].containsKey(provider.type)),
      _assertRegisterMessage('already', name, provider.type),
    );

    _namedProviders.putIfAbsent(
        name, () => <String, _Provider>{})[provider.type] = provider;
  }

  String _assertRegisterMessage(String word, String name, String type) {
    return 'The type $type was $word registered${name == null ? '' : ' for the name $name'} => loading stack: $_loadingStack';
  }
}

T invalidProvider<T>(String message) {
  throw message;
}

class _Provider {
  _Provider.instance(this.object, this.type)
      : assert(object != null),
        assert(type != null),
        instanceBuilder = null,
        eagerInit = false,
        _oneTime = false;

  _Provider.factory(this.instanceBuilder, this.type)
      : assert(type != null),
        eagerInit = false,
        _oneTime = false;

  _Provider.singleton(this.instanceBuilder,
      {@required this.type, this.eagerInit = false})
      : assert(type != null),
        _oneTime = true;

  final String type;
  final Factory instanceBuilder;
  Instance object;
  bool _oneTime = false;

  /// Only applies to singletons
  final bool eagerInit;

  Instance get(Container container) {
    try {
      if (_oneTime && instanceBuilder != null) {
        final inst = instanceBuilder(container);
        if (inst is LifecycleAware) {
          object = Instance(inst,
              init:
                  Future.value((inst).onLifecycleEvent(LifecycleEvent.start)));
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
          return Instance(inst,
              init: Future.value(inst.onLifecycleEvent(LifecycleEvent.start)));
        } else {
          return Instance(inst);
        }
      }

      return null;
    } catch (e, stack) {
      _log.severe("Error constructing", e, stack);
      rethrow;
    }
  }

  @override
  String toString() {
    var str = '$type { ';
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

class Instance {
  final Object value;
  final Completer _completer;

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

  Future get ready => _completer.future;
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

  @override
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

  Future autoSubscribe(
      String name, LifecycleCallback<StreamSubscription> generate) async {
    onInit(name, () async {
      final subscribe = await generate();

      onDestroy(name, () async {
        await subscribe.cancel();
      });
    });
  }

  Future autoStream<T>(String name, LifecycleCallback<Stream<T>> stream,
      {bool cancelOnError = false}) async {
    onInit(name, () async {
      final subscribe = (await stream()).listen((_) {}, cancelOnError: false);

      onDestroy(name, () async {
        await subscribe.cancel();
      });
    });
  }

  @override
  @mustCallSuper
  FutureOr onLifecycleEvent(LifecycleEvent event) async {
    assert(
        hasBeenInitialized == true,
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
