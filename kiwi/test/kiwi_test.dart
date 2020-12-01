import 'package:kiwi/kiwi.dart';
import 'package:matcher/matcher.dart';
import 'package:test/test.dart';

void main() {
  Container container = Container();

  group('Silent=true tests', () {
    setUp(() {
      container.clear();
      container.silent = true;
    });

    test('containers should be the same', () {
      Container c1 = Container();
      Container c2 = Container();
      expect(c1, c2);
    });

    test('instances should be resolved', () {
      var person = Character('Anakin', 'Skywalker');
      container.registerInstance(5);
      container.registerInstance(6, name: 'named');
      container.registerInstance<num, int>(
        7,
      );
      container.registerInstance(person);

      expect(container<int>(), 5);
      expect(container<int>('named'), 6);
      expect(container<num>(), 7);
      expect(container<num>('named'), null);
      expect(container<Character>(), person);
    });

    test('container should resolve when called', () {
      var person = Character('Anakin', 'Skywalker');
      container.registerInstance(5);
      container.registerInstance(6, name: 'named');
      container.registerInstance<num, int>(
        7,
      );
      container.registerInstance(person);

      expect(container<int>(), 5);
      expect(container<int>('named'), 6);
      expect(container<num>(), 7);
      expect(container<num>('named'), null);
      expect(container<Character>(), person);
    });

    test('instances can be overridden', () {
      container.registerInstance(5);
      expect(container<int>(), 5);

      container.registerInstance(6);
      expect(container<int>(), 6);
    });

    test('Cant register dynamic singleton', () {
      expect(() {
        container.registerSingleton((container) {
          return "factory" as dynamic;
        });
      }, throwsA(anything));
    });

    test('Cant retrieve dynamic singleton', () {
      expect(() {
        container.registerSingleton<String, String>((container) {
          container<dynamic>();
          return "Foo";
        });
        return container<String>();
      }, throwsA(anything));
    });

    test('builders should be resolved', () {
      container.registerSingleton((c) => 5);
      container.registerFactory(
          (c) => const Sith('Anakin', 'Skywalker', 'DartVader'));
      container.registerFactory<Character, Sith>(
          (c) => const Character('Anakin', 'Skywalker'));

      expect(container<int>(), 5);
      expect(container<Sith>(), const Sith('Anakin', 'Skywalker', 'DartVader'));
      expect(container<Character>(), const Character('Anakin', 'Skywalker'));
    });

    test('builders should always be created', () {
      container.registerFactory((c) => Character('Anakin', 'Skywalker'));

      expect(container<Character>(), isNot(same(container<Character>())));
    });

    test('one time builders should be resolved', () {
      container.registerSingleton((c) => 5);
      container.registerSingleton(
          (c) => const Sith('Anakin', 'Skywalker', 'DartVader'));
      container.registerSingleton<Character, Sith>(
          (c) => const Character('Anakin', 'Skywalker'));

      expect(container<int>(), 5);
      expect(container<Sith>(), const Sith('Anakin', 'Skywalker', 'DartVader'));
      expect(container<Character>(), const Character('Anakin', 'Skywalker'));
    });

    test('one time builders should be created one time only', () {
      container.registerSingleton((c) => Character('Anakin', 'Skywalker'));

      expect(container<Character>(), container<Character>());
    });

    test('unregister should remove items from container', () {
      container.registerInstance(5);
      container.registerInstance(6, name: 'named');

      expect(container<int>(), 5);
      expect(container<int>('named'), 6);

      container.unregister<int>();
      expect(container<int>(), null);

      container.unregister<int>(name: 'named');
      expect(container<int>('named'), null);
    });
  });

  group('Silent=false tests', () {
    setUp(() {
      container.clear();
      container.silent = false;
    });

    test('instances cannot be overridden', () {
      container.registerInstance(5);
      expect(container<int>(), 5);

      container.registerInstance(8, name: 'name');
      expect(container<int>('name'), 8);

      expect(
          () => container.registerInstance(6),
          throwsA(TypeMatcher<AssertionError>().having(
            (f) => f.message,
            'message',
            startsWith('The type int was already registered'),
          )));

      expect(
          () => container.registerInstance(9, name: 'name'),
          throwsA(TypeMatcher<AssertionError>().having(
            (f) => f.message,
            'message',
            startsWith('The type int was already registered for the name name'),
          )));
    });

    test('values should exist when unregistering', () {
      expect(
          () => container.unregister<int>(),
          throwsA(TypeMatcher<AssertionError>().having(
            (f) => f.message,
            'message',
            startsWith('The type int was not registered'),
          )));

      expect(
          () => container.unregister<int>(name: 'name'),
          throwsA(TypeMatcher<AssertionError>().having(
            (f) => f.message,
            'message',
            startsWith('The type int was not registered for the name name'),
          )));
    });

    test('values should exist when resolving', () {
      expect(
          () => container<int>(),
          throwsA(TypeMatcher<AssertionError>().having(
            (f) => f.message,
            'message',
            startsWith('No component registered for int'),
          )));

      expect(
          () => container<int>('name'),
          throwsA(TypeMatcher<AssertionError>().having(
            (f) => f.message,
            'message',
            'No component registered for int name=name',
          )));
    });
  });
}

class Character {
  const Character(
    this.firstName,
    this.lastName,
  );

  final String firstName;
  final String lastName;
}

class Sith extends Character {
  const Sith(
    String firstName,
    String lastName,
    this.id,
  ) : super(firstName, lastName);

  final String id;
}
