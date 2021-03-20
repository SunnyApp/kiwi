import 'package:sunny_kiwi/sunny_kiwi.dart';

void main() {
  Container container = Container();
  container.registerInstance(Logger());
  container.registerSingleton((c) => Logger(), name: 'logA');
  container.registerFactory((c) => ServiceA(c<Logger>('logA')));
}

class Service {}

class ServiceA extends Service {
  // ignore: avoid_unused_constructor_parameters
  ServiceA(Logger? logger);
}

class Logger {}
