parts = ~w(head_neck hand_l hand_r pelvis lumbar5 thoracic12 thoracic1 clavicle_l humerus_l radius_l
           clavicle_r humerus_r radius_r femur_l tibia_l calcn_l toes_l femur_r tibia_r calcn_r toes_r)

[src, dst] = System.argv()

rows =
  src
  |> File.read!()
  |> String.split("\n")
  |> Enum.drop_while(&(not String.starts_with?(&1, "# anny_bone")))
  |> Enum.drop(1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.map(fn line ->
    [bone, body, pair] = String.split(line, "\t")

    names =
      case pair do
        "None" -> ["", "", "", ""]
        _ -> Regex.scan(~r/'([^']+)'/, pair, capture: :all_but_first) |> List.flatten()
      end

    4 = length(names)
    [bone, body | names]
  end)

bodies = rows |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()
[] = bodies -- parts
[] = parts -- bodies

sorted = Enum.flat_map(parts, fn p -> Enum.filter(rows, &(Enum.at(&1, 1) == p)) end)
true = length(sorted) == length(rows)
head = ~w(anny_bone mujoco_body anny_from anny_to mujoco_from mujoco_to)
File.write!(dst, Enum.map_join([head | sorted], "", &(Enum.join(&1, "\t") <> "\n")))
IO.puts("#{length(sorted)} rows, #{length(bodies)} driving bodies -> #{dst}")
