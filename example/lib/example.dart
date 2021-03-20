import 'package:example/src/models/coffee_maker.dart';
import 'package:example/src/modules/drip_coffee_module.dart';
import 'package:sunny_kiwi/sunny_kiwi.dart';

void main() {
  CoffeeInjector coffeeInjector = getCoffeeInjector();
  coffeeInjector.configure();

  Container container = Container();

  CoffeeMaker coffeeMaker = container<CoffeeMaker>();
  coffeeMaker.brew();
}
