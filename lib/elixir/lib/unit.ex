defmodule Unit do
  defstruct [:value, :unit]

  @measurement_types %{
    length: %{
      m: 1.0,
      km: 1000.0,
      cm: 0.01,
      mm: 0.001,
      inch: 0.0254,
      mile: 1609.344
    },
    mass: %{
      g: 1.0,
      kg: 1000.0,
      mg: 0.001,
      t: 1_000_000.0
    },
    time: %{
      s: 1.0,
      min: 60.0,
      h: 3600.0,
      ms: 0.001,
      us: 0.000001,
      ns: 0.000000001
    }
  }
  def add(first, second) do
    calculate(first, second, &+/2)
  end

  def subtract(first, second) do
    calculate(first, second, &-/2)
  end

  def mult(first, second) do
    calculate(first, second, &*/2)
  end

  def div(first, second) do
    calculate(first, second, &//2)
  end

  def negate(%Unit{value: value} = unit) do
    %{unit | value: -value}
  end

  defp calculate(%Unit{unit: unit} = first, %Unit{unit: unit} = second, operation) do
    %Unit{value: operation.(first.value, second.value), unit: unit}
  end

  defp calculate(%Unit{unit: unit1} = first, %Unit{unit: unit2} = second, operation) do
    type1 = get_type(unit1)
    type2 = get_type(unit2)

    if type1 != type2 do
      raise "Cannot perform operations on different measurement types: #{inspect(first)} (#{type1}) and #{inspect(second)} (#{type2})"
    end

    base_value1 = to_base_value(first)
    base_value2 = to_base_value(second)
    result_base_value = operation.(base_value1, base_value2)
    result_value = from_base_value(result_base_value, unit1)
    %Unit{value: result_value, unit: unit1}
  end

  defp get_type(unit) do
    Enum.find_value(@measurement_types, fn {type, units} ->
      units[unit] && type
    end) || raise "unknown unit #{unit}"
  end

  defp to_base_value(%Unit{value: value, unit: unit}) do
    type = get_type(unit)
    value * @measurement_types[type][unit]
  end

  defp from_base_value(base_value, unit) do
    type = get_type(unit)
    base_value / @measurement_types[type][unit]
  end
end

defimpl Inspect, for: Unit do
  def inspect(%Unit{value: value, unit: unit}, _) do
    "#{value} #{unit}"
  end
end
